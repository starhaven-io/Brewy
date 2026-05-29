@testable import Brewy
import Foundation
import Testing

// MARK: - Services Parsing Tests

@Suite("Services JSON Parsing")
struct ServicesParsingTests {

    @Test("parseJSON parses running service from info format")
    func parseRunningService() {
        let json = """
        [{"name":"postgresql@14","service_name":"homebrew.mxcl.postgresql@14","running":true,"loaded":true,\
        "pid":1234,"exit_code":0,"user":"patrick","status":"started",\
        "file":"/Users/patrick/Library/LaunchAgents/homebrew.mxcl.postgresql@14.plist",\
        "log_path":"/opt/homebrew/var/log/postgresql@14.log",\
        "error_log_path":"/opt/homebrew/var/log/postgresql@14.log"}]
        """
        let services = ServicesParser.parseJSON(json)
        #expect(services.count == 1)
        #expect(services[0].name == "postgresql@14")
        #expect(services[0].running == true)
        #expect(services[0].loaded == true)
        #expect(services[0].pid == 1_234)
        #expect(services[0].user == "patrick")
        #expect(services[0].statusLabel == "Running")
        #expect(services[0].serviceName == "homebrew.mxcl.postgresql@14")
    }

    @Test("parseJSON parses stopped service from info format")
    func parseStoppedService() {
        let json = """
        [{"name":"redis","service_name":"homebrew.mxcl.redis","running":false,"loaded":false,\
        "pid":null,"exit_code":null,"user":null,"status":"none",\
        "file":"/opt/homebrew/opt/redis/homebrew.mxcl.redis.plist",\
        "log_path":null,"error_log_path":null}]
        """
        let services = ServicesParser.parseJSON(json)
        #expect(services.count == 1)
        #expect(services[0].name == "redis")
        #expect(services[0].running == false)
        #expect(services[0].loaded == false)
        #expect(services[0].statusLabel == "Stopped")
    }

    @Test("parseJSON parses multiple services")
    func parseMultipleServices() {
        let json = """
        [{"name":"postgresql@14","service_name":"homebrew.mxcl.postgresql@14","running":true,"loaded":true,\
        "pid":1234,"exit_code":0,"user":"patrick","status":"started",\
        "file":null,"log_path":null,"error_log_path":null},\
        {"name":"redis","service_name":"homebrew.mxcl.redis","running":false,"loaded":true,\
        "pid":null,"exit_code":0,"user":"patrick","status":"stopped",\
        "file":null,"log_path":null,"error_log_path":null}]
        """
        let services = ServicesParser.parseJSON(json)
        #expect(services.count == 2)
        #expect(services[0].running == true)
        #expect(services[1].running == false)
        #expect(services[1].statusLabel == "Stopped")
    }

    @Test("parseJSON parses compact list format without running/loaded fields")
    func parseCompactListFormat() {
        let json = """
        [{"name":"container","status":"stopped","user":"patrick",\
        "file":"/Users/patrick/Library/LaunchAgents/homebrew.mxcl.container.plist","exit_code":0},\
        {"name":"unbound","status":"none","user":null,\
        "file":"/opt/homebrew/opt/unbound/homebrew.mxcl.unbound.plist","exit_code":null}]
        """
        let services = ServicesParser.parseJSON(json)
        #expect(services.count == 2)
        #expect(services[0].name == "container")
        #expect(services[0].status == "stopped")
        #expect(services[0].user == "patrick")
        #expect(services[0].running == false)
        #expect(services[0].statusLabel == "Stopped")
        #expect(services[1].name == "unbound")
        #expect(services[1].status == "none")
        #expect(services[1].user == nil)
        #expect(services[1].statusLabel == "Stopped")
    }

    @Test("parseJSON handles empty output")
    func parseEmpty() {
        let services = ServicesParser.parseJSON("")
        #expect(services.isEmpty)
    }

    @Test("parseJSON handles empty array")
    func parseEmptyArray() {
        let services = ServicesParser.parseJSON("[]")
        #expect(services.isEmpty)
    }

    @Test("BrewServiceItem statusLabel returns correct values")
    func statusLabels() {
        let running = BrewServiceItem(
            name: "test", serviceName: nil, running: true, loaded: true,
            pid: 123, exitCode: 0, user: nil, status: "started",
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(running.statusLabel == "Running")

        let startedViaStatus = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: false,
            pid: nil, exitCode: 0, user: nil, status: "started",
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(startedViaStatus.statusLabel == "Running")

        let noneStatus = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: true,
            pid: nil, exitCode: 0, user: nil, status: "none",
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(noneStatus.statusLabel == "Stopped")

        let loadedNoStatus = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: true,
            pid: nil, exitCode: 0, user: nil, status: nil,
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(loadedNoStatus.statusLabel == "Loaded")

        let stopped = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: false,
            pid: nil, exitCode: nil, user: nil, status: nil,
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(stopped.statusLabel == "Stopped")
    }

    @Test("BrewServiceItem is Identifiable by name")
    func serviceIdentifiable() {
        let service = BrewServiceItem(
            name: "postgresql@14", serviceName: nil, running: true, loaded: true,
            pid: nil, exitCode: nil, user: nil, status: nil,
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(service.id == "postgresql@14")
    }

    @Test("BrewServiceItem isHealthy logic")
    func serviceHealthy() {
        let running = BrewServiceItem(
            name: "test", serviceName: nil, running: true, loaded: true,
            pid: 123, exitCode: 0, user: nil, status: "started",
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(running.isHealthy == true)

        let stoppedClean = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: false,
            pid: nil, exitCode: nil, user: nil, status: nil,
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(stoppedClean.isHealthy == true)

        let loadedNotRunning = BrewServiceItem(
            name: "test", serviceName: nil, running: false, loaded: true,
            pid: nil, exitCode: 1, user: nil, status: "error",
            file: nil, logPath: nil, errorLogPath: nil
        )
        #expect(loadedNotRunning.isHealthy == false)
    }
}

// MARK: - Services Control

@Suite("BrewService Services Control")
@MainActor
struct BrewServiceServicesControlTests {

    @Test("startService issues `services start <name>` via brew")
    func startServiceCommand() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)

        _ = await service.startService("redis")

        let last = mock.executedExecutables.last
        #expect(last?.arguments == ["services", "start", "redis"])
        #expect(last?.path.hasSuffix("brew") == true)
    }

    @Test("stopService and restartService issue the matching verbs")
    func stopAndRestartCommands() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)

        _ = await service.stopService("redis")
        #expect(mock.executedExecutables.last?.arguments == ["services", "stop", "redis"])

        _ = await service.restartService("redis")
        #expect(mock.executedExecutables.last?.arguments == ["services", "restart", "redis"])
    }

    @Test("asSudo runs brew via osascript with administrator privileges")
    func startServiceAsSudo() async {
        let mock = MockCommandRunner()
        let (service, _) = makeService(mock: mock)

        _ = await service.startService("redis", asSudo: true)

        // osascript -e <privileged script> <brewPath> services start redis
        let args = mock.executedExecutables.last?.arguments ?? []
        #expect(mock.executedExecutables.last?.path == "/usr/bin/osascript")
        #expect(args.first == "-e")
        #expect(args.dropFirst().first?.contains("administrator privileges") == true)
        #expect(args.dropFirst(2).first?.hasSuffix("brew") == true)
        #expect(Array(args.suffix(3)) == ["services", "start", "redis"])
    }
}
