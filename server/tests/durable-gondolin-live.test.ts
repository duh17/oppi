import { mkdtempSync, symlinkSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { BACKGROUND_CONTEXT as context, withAbortSignal } from "@earendil-works/chord/context";
import { createEditTool } from "@earendil-works/pi-durable/tools";
import {
  GondolinManager,
  isQemuAvailable,
  sandboxUnsupportedNodeMessage,
} from "../src/gondolin-manager.js";
import { GondolinExecutionEnv } from "../src/durable-gondolin-env.js";
import type { GondolinVm } from "../src/gondolin-ops.js";

// Match the other live VM suites: absent prerequisites return early, but VM
// boot and assertion failures after a successful preflight must still fail.
let qemuAvailable = false;
beforeAll(async () => {
  const nodeError = sandboxUnsupportedNodeMessage();
  if (nodeError) {
    console.log(`[durable-security] Skipping: ${nodeError}`);
    return;
  }
  qemuAvailable = await isQemuAvailable();
  if (!qemuAvailable) console.log("[durable-security] Skipping: QEMU not installed");
}, 10_000);

describe("Durable shared guest security", { timeout: 30_000 }, () => {
  const root = "/workspace/durable-security";
  let host: string;
  let vm: GondolinVm;
  let manager: GondolinManager;
  const noLiveGroupMembers = async (pgid: string): Promise<boolean> =>
    (
      await vm.exec([
        "/bin/sh",
        "-c",
        [
          'p="$1"',
          "for f in /proc/[0-9]*/stat; do",
          '  IFS= read -r s < "$f" || continue',
          "  fields=${s##*) }; set -- $fields",
          '  if [ "$3" = "$p" ]; then echo "$s"; [ "$1" = Z ] || exit 1; fi',
          "done",
        ].join("\n"),
        "probe-group",
        pgid,
      ])
    ).ok;
  beforeAll(async () => {
    if (!qemuAvailable) return;
    host = mkdtempSync(join(tmpdir(), "oppi-durable-security-"));
    console.log("durable security artifacts:", host);
    manager = new GondolinManager();
    vm = await manager.ensureWorkspaceVm(
      {
        id: `durable-security-${process.pid}`,
        name: "Durable Security",
        runtime: "sandbox",
        sandboxConfig: { allowedHosts: [] },
        createdAt: 1,
        updatedAt: 1,
      },
      host,
      {},
      [],
      {},
      root,
    );
  }, 120_000);
  afterAll(async () => {
    await manager?.stopAll();
  }, 30_000);

  it.each(["1", "sibling", "empty", "deleted"])(
    "Stop ignores %s forged pid files and preserves a sibling conversation",
    async (attack) => {
      if (!qemuAvailable) return;
      let killArgs: string[] | undefined;
      const victim = new GondolinExecutionEnv(
        {
          ...vm,
          fs: vm.fs,
          exec: (args, options) => {
            if (Array.isArray(args) && args.includes("oppi-kill")) killArgs = args;
            return vm.exec(args, options);
          },
        },
        "security",
        root,
      );
      const sibling = new GondolinExecutionEnv(vm, "security", root);
      const victimAbort = new AbortController();
      const siblingAbort = new AbortController();
      const started = (env: GondolinExecutionEnv, abort: AbortController, name: string) => {
        let resolve!: (pid: string) => void;
        const ready = new Promise<string>((r) => {
          resolve = r;
        });
        const done = env.exec(
          `echo READY $$; sleep 30; echo late > ${name}.txt`,
          {
            onOutput: (text) => {
              const match = /READY ([0-9]+)/.exec(text);
              if (match) resolve(match[1]);
            },
          },
          withAbortSignal(abort.signal, context),
        );
        return {
          ready: Promise.race([
            ready,
            done.then(() => {
              throw new Error("Command ended before ready");
            }),
          ]),
          done,
        };
      };
      const a = started(victim, victimAbort, `victim-${attack}`);
      const b = started(sibling, siblingAbort, `sibling-${attack}`);
      try {
        const [target, other] = await Promise.all([a.ready, b.ready]);
        const forge = await vm.exec([
          "/bin/sh",
          "-c",
          [
            "touch /tmp/oppi-durable-pgid-forged",
            "for f in /tmp/oppi-durable-pgid-*; do",
            attack === "deleted"
              ? 'rm -f "$f"'
              : attack === "empty"
                ? ': > "$f"'
                : 'printf "%s\\n" "$1" > "$f"',
            "done",
          ].join("\n"),
          "forge",
          attack === "sibling" ? other : "1",
        ]);
        expect(forge.ok).toBe(true);
        victimAbort.abort();
        const result = await a.done;
        expect(result.ok).toBe(false);
        if (!result.ok) expect(result.error.code).toBe("aborted");
        // kill -0 also succeeds for dead, unreaped zombies. The safety oracle
        // is no runnable group member (not PID 1's unrelated reaping policy).
        await expect
          .poll(() => noLiveGroupMembers(target), { timeout: 2000, interval: 10 })
          .toBe(true);
        expect((await vm.exec(["/bin/sh", "-c", 'kill -0 -"$1"', "probe", other])).ok).toBe(true);
        expect((await victim.readTextFile(`victim-${attack}.txt`, context)).ok).toBe(false);
        expect(killArgs).toBeDefined();
        // The exact production kill script accepts only group ESRCH as a no-op.
        const absent = "2147483647";
        expect((await vm.exec(["/bin/sh", "-c", 'kill -0 -"$1"', "probe", absent])).ok).toBe(false);
        expect((await vm.exec([...killArgs!.slice(0, 4), absent, "12345"])).ok).toBe(true);
        if (attack === "1") {
          for (const forged of ["0", "1", "01", "-1", "42x", "4294967297"]) {
            expect((await vm.exec([...killArgs!.slice(0, 4), forged, "12345"])).ok).toBe(false);
          }
          // A live sibling pgid with the wrong lifetime must not be signaled.
          expect((await vm.exec([...killArgs!.slice(0, 4), other, "999999999999999"])).ok).toBe(
            false,
          );
          expect((await vm.exec(["/bin/sh", "-c", 'kill -0 -"$1"', "probe", other])).ok).toBe(true);
          // A gone leader leaves its existing group safe to kill; a recycled
          // leader would have /proc/<pid>/stat and fail the lifetime check.
          const detached = await vm.exec([
            "/usr/bin/setsid",
            "/bin/sh",
            "-c",
            "sleep 30 >/dev/null 2>&1 & echo $$",
          ]);
          const orphan = detached.stdout.trim();
          expect(detached.ok).toBe(true);
          expect(orphan).toMatch(/^[1-9][0-9]*$/);
          try {
            expect((await vm.exec(["/bin/sh", "-c", 'kill -0 -"$1"', "probe", orphan])).ok).toBe(
              true,
            );
            expect((await vm.exec([...killArgs!.slice(0, 4), orphan, "12345"])).ok).toBe(true);
            await expect
              .poll(() => noLiveGroupMembers(orphan), { timeout: 2000, interval: 10 })
              .toBe(true);
            expect((await vm.exec(["/bin/sh", "-c", 'kill -0 -"$1"', "probe", other])).ok).toBe(
              true,
            );
          } finally {
            await vm.exec(["/bin/sh", "-c", 'kill -KILL -"$1"', "owned-orphan-cleanup", orphan]);
          }
          console.log(
            "PASS kill boundary: invalid targets and lifetime mismatch refused; orphan group killed, sibling alive; group ESRCH accepted",
          );
        }
        console.log(
          `PASS forged pid file ${attack}: victim group has no live members, sibling group alive`,
        );
      } finally {
        victimAbort.abort();
        siblingAbort.abort();
        await Promise.all([a.done, b.done]);
        await Promise.all([victim.cleanup(context), sibling.cleanup(context)]);
      }
    },
  );

  it("concurrent edits through a symlink and its target both land", async () => {
    if (!qemuAvailable) return;
    const env = new GondolinExecutionEnv(vm, "security", root);
    writeFileSync(join(host, "note.txt"), "one\ntwo\n");
    symlinkSync("note.txt", join(host, "link.txt"));
    expect(await env.canonicalPath("link.txt", context)).toEqual({
      ok: true,
      value: `${root}/note.txt`,
    });
    expect(await env.canonicalPath("note.txt", context)).toEqual({
      ok: true,
      value: `${root}/note.txt`,
    });
    const edit = createEditTool();
    const api = { env } as Parameters<typeof edit.execute>[1];
    await Promise.all([
      edit.execute({ path: "link.txt", edits: [{ oldText: "one", newText: "ONE" }] }, api, context),
      edit.execute({ path: "note.txt", edits: [{ oldText: "two", newText: "TWO" }] }, api, context),
    ]);
    expect(readFileSync(join(host, "note.txt"), "utf8")).toBe("ONE\nTWO\n");
  });

  it("rejects a resolved guest symlink outside the workspace", async () => {
    if (!qemuAvailable) return;
    expect((await vm.exec(["ln", "-s", "/etc", `${root}/outside`])).ok).toBe(true);
    const env = new GondolinExecutionEnv(vm, "security", root);
    const result = await env.canonicalPath("outside", context);
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error.code).toBe("permission_denied");
  });
});
