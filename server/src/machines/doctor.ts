import { MachineRegistry } from "./registry.js";

/** One `oppi doctor` line per machine, from its last test; no network. */
export function machineDoctorChecks(
  dataDir: string,
): { level: "pass" | "warn" | "fail"; message: string }[] {
  let machines;
  try {
    machines = new MachineRegistry(dataDir).list();
  } catch (error) {
    return [
      {
        level: "warn",
        message: `machines.json is unreadable (${error instanceof Error ? error.message : String(error)})`,
      },
    ];
  }
  return machines.map((machine) => {
    if (!machine.test)
      return {
        level: "warn",
        message: `machine ${machine.name}: not tested (\`oppi machines test ${machine.name}\`)`,
      };
    const failed = machine.test.checks.filter((check) => check.required && !check.ok);
    return machine.test.ok
      ? {
          level: "pass",
          message: `machine ${machine.name}: last test passed (${new Date(machine.test.at).toISOString()})`,
        }
      : {
          level: "warn",
          message: `machine ${machine.name}: last test failed (${failed.map((check) => check.name).join(", ")}); \`oppi machines test ${machine.name}\``,
        };
  });
}
