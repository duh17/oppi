import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { makeTempDir } from "./harness/temp-dir.js";

// `oppi/v1` as an outside plugin author gets it: the server package installed under the name
// `oppi` (`npm install --save-dev oppi@npm:oppi-server`), resolved through its `exports`, with
// no path mapping. The shipped example plugins, copied out of the repository, must type-check
// against it, and so must the panel example the docs print.

const serverRoot = fileURLToPath(new URL("..", import.meta.url));
const tsc = join(serverRoot, "node_modules", "@typescript", "native", "bin", "tsc");
const EXAMPLES = ["example-board", "example-bookmarks", "example-release-notes"];

/** A folder outside the repository with the package installed as `oppi`, its types built. */
function installedPackage(): string {
  const root = makeTempDir("oppi-plugin-types-");
  const pkg = join(root, "node_modules", "oppi");
  mkdirSync(pkg, { recursive: true });
  copyFileSync(join(serverRoot, "package.json"), join(pkg, "package.json"));
  // The published declarations, as `npm run build` writes them into the package's dist/types.
  execFileSync(
    process.execPath,
    [tsc, "-p", "tsconfig.v1-types.json", "--declarationDir", join(pkg, "dist", "types")],
    { cwd: serverRoot, stdio: "pipe" },
  );
  // The package's dependencies, which npm installs beside it.
  for (const scope of ["@earendil-works", "@types"])
    symlinkSync(join(serverRoot, "node_modules", scope), join(root, "node_modules", scope), "dir");
  return root;
}

function typecheck(root: string, files: Record<string, string>): string {
  const plugin = join(root, "my-plugin");
  mkdirSync(plugin, { recursive: true });
  for (const [name, source] of Object.entries(files)) writeFileSync(join(plugin, name), source);
  writeFileSync(
    join(plugin, "tsconfig.json"),
    JSON.stringify({
      compilerOptions: {
        target: "ES2022",
        module: "NodeNext",
        moduleResolution: "NodeNext",
        strict: true,
        noEmit: true,
        skipLibCheck: true,
      },
      include: ["*.ts"],
    }),
  );
  try {
    execFileSync(process.execPath, [tsc, "-p", plugin], { stdio: "pipe" });
    return "";
  } catch (error) {
    return String((error as { stdout?: Buffer }).stdout ?? error);
  }
}

describe("oppi/v1 published types", () => {
  it("type-check an outside plugin folder, and reject a plugin that misuses the API", () => {
    const root = installedPackage();
    const files: Record<string, string> = {};
    for (const example of EXAMPLES)
      files[`${example}.ts`] = readFileSync(
        join(serverRoot, "plugins", example, "server.ts"),
        "utf8",
      );
    // Real types, not `any`: each misuse below must be an error for its expectation to hold.
    files["misuse.ts"] = [
      'import { surface } from "oppi/v1";',
      'import { str } from "oppi/v1/schema";',
      "// @ts-expect-error a surface needs a view",
      'surface<{ n: number }>({ id: "x", title: "X" });',
      "// @ts-expect-error a string schema takes options, not a number",
      "str(1);",
      "",
    ].join("\n");
    expect(typecheck(root, files)).toBe("");
  });

  it("prints the shipped panel example in the docs, as it is", () => {
    const docs = readFileSync(join(serverRoot, "..", "docs", "extension-native-ui.md"), "utf8");
    const example = readFileSync(join(serverRoot, "plugins", "example-board", "server.ts"), "utf8");
    expect(docs).toContain(["```ts", example.trimEnd(), "```"].join("\n"));
  });
});
