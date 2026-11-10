//
//  main.swift
//  TuttoHelper
//
//  Root LaunchDaemon (registered by Tutto.app through SMAppService) that writes fan
//  speeds to the SMC and keeps the Mac awake for Stay Awake. launchd starts it on demand
//  when the app connects to the `ca.bryanyao.Tutto.helper` Mach service. It exits about
//  15 s after the last client leaves, with every fan back on automatic and no session
//  running. See docs/fan-helper.md.
//
//  Shared sources (protocol, SMC encoding, write sequence) are symlinked from
//  Sources/TuttoKit/Sensors into Shared/, so this binary links only Foundation, IOKit
//  and CBridges.
//

import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = CommandLine.arguments.dropFirst()

if arguments.contains("--version") {
    print(TuttoFanHelper.version)
    exit(0)
}
if arguments.contains("--self-test") {
    exit(SelfTest.run())
}
// Only launchd (pid 1) should start the daemon; a stray manual launch would sit idle.
guard getppid() == 1 else {
    print("""
    TuttoHelper \(TuttoFanHelper.version): Tutto's fan helper. launchd starts it for Tutto.app.
      --self-test   check sensors, the client signature requirement and the privilege boundary (changes nothing)
      --version     print the helper version
    """)
    exit(64)
}
if geteuid() != 0 {
    log.error("not running as root; SMC writes will fail with kIOReturnNotPrivileged")
}

let service = HelperService(smc: SMCDevice.shared)
let listener = NSXPCListener(machServiceName: TuttoFanHelper.machServiceName)
service.attach(to: listener)
service.startDaemonDuties()
listener.resume()
log.notice("TuttoHelper \(TuttoFanHelper.version, privacy: .public) listening on \(TuttoFanHelper.machServiceName, privacy: .public)")
dispatchMain()
