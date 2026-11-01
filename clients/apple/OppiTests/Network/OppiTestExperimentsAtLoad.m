// The test bundle's experiments are on before any test runs: a load-time
// constructor reaches the Swift seeder (`OppiTestExperiments.swift`), which
// XCTest's own principal class could not do here (see that file).
extern void OppiSeedTestExperiments(void);

__attribute__((constructor)) static void OppiSeedTestExperimentsAtLoad(void) {
    OppiSeedTestExperiments();
}
