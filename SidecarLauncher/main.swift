//
//  SidecarLauncher
//  CLI to connect to a Sidecar device.
//
//  Created by Jovany Ocasio
//

import Foundation

enum Command : String {
    case Devices    = "devices"
    case Connect    = "connect"
    case Disconnect = "disconnect"
    case Toggle     = "toggle"
}
enum Option : String {
    case WiredConnection = "-wired"
}

func printHelp() {
    let sidecarLauncher = "./SidecarLauncher"
    let help = """
        Commands:
            \(Command.Devices.rawValue)
                       List names of reachable sidecar capable devices.
                       Example: \(sidecarLauncher) \(Command.Devices.rawValue)
        
            \(Command.Connect.rawValue) <device_name> [\(Option.WiredConnection.rawValue)]
                       Connect to device with the specified name. Use quotes aroung device_name.
                       Example: \(sidecarLauncher) \(Command.Connect.rawValue) "Joe's iPad" \(Option.WiredConnection.rawValue)
                       
                       WARNING:
                       \(Option.WiredConnection.rawValue) is an experimental option that tries to force a wired connection when initializing a Sidecar
                       session. The information below is based on limited observations.
                       An error is returned if there is no cable connected. It will not fallback to a wireless connection.
                       Once the connection succeeds with this option, the Sidecar session will *only* work with a cable
                       connection. If the cable is disconnected, it will not automatically fallback to a wireless connection.
                       Nor will it automatically reconnect when the cable is reconnected. The session needs to be terminated
                       and a new connection needs to be established.
        
            \(Command.Disconnect.rawValue) <device_name>
                       Disconnect from device with the specified name. Use quotes.
                       Example: \(sidecarLauncher) \(Command.Disconnect.rawValue) "Joe's iPad"

            \(Command.Toggle.rawValue)
                       If connected, disconnects from the current device.
                       If not connected, lists devices and connects to the first one.
                       Example: \(sidecarLauncher) \(Command.Toggle.rawValue)
        
        Exit Codes:
            0    Command completed successfully
            1    Invalid input
            2    No reachable Sidecar devices detected
            4    SidecarCore private error encountered
        """
    print(help)
}

if (CommandLine.arguments.count == 1) {
    print("A command was not specified")
    printHelp()
    exit(1)
}

let cmdArg = CommandLine.arguments[1].lowercased()
guard let cmd = Command(rawValue: cmdArg) else {
    print("Invalid command specified: \(cmdArg)")
    printHelp()
    exit(1)
}

let targetDeviceName: String
var option: Option?
if (cmd == .Connect || cmd == .Disconnect) {
    if (CommandLine.arguments.count == 2) {
        print("A device name not specified")
        printHelp()
        exit(1)
    }
    
    targetDeviceName = CommandLine.arguments[2].lowercased()
    
    if (CommandLine.arguments.count > 3) {
        let optionArg = CommandLine.arguments[3].lowercased()
        guard let validOption = Option(rawValue: optionArg) else {
            print("Invalid option specified: \(optionArg)")
            printHelp()
            exit(1)
        }
        option = validOption
    }
} else {
    targetDeviceName = ""
}

guard let _ = dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY) else {
    fatalError("SidecarCore framework failed to open")
}

guard let cSidecarDisplayManager = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
    fatalError("SidecarDisplayManager class not found")
}

guard let manager = cSidecarDisplayManager.perform(Selector(("sharedManager")))?.takeUnretainedValue() else {
    fatalError("Failed to get instance of SidecarDisplayManger")
}

guard let devices = manager.perform(Selector(("devices")))?.takeUnretainedValue() as? [NSObject] else {
    fatalError("Failed to query reachable sidecar devices")
}

if (devices.isEmpty) {
    print("No sidecar capable devices detected")
    exit(2)
}

if (cmd == .Connect || cmd == .Disconnect) {
    let targetDevice = devices.first(where: {
        let name = $0.perform(Selector(("name")))?.takeUnretainedValue() as! String
        return name.lowercased() == targetDeviceName
    })
    
    guard let targetDevice = targetDevice else {
        print("""
              \(targetDeviceName) is not in the list of available devices.
              Verify device name. For example "Joe's iPad" is different from "Joe's iPad" (notice the apostrophe)
              For accuracy, list the available devices and copy paste the device name.
              """)
        exit(3)
    }
    
    let dispatchGroup = DispatchGroup()
    let closure: @convention(block) (_ e: NSError?) -> Void = { e in
        defer {
            dispatchGroup.leave()
        }
        
        if let e = e {
            print("Error during \(cmd.rawValue): \(e.localizedDescription)")
            if let underlyingError = e.userInfo[NSUnderlyingErrorKey] as? NSError {
                 print("Underlying Error: \(underlyingError.localizedDescription)")
            }
            exit(4)
        } else {
            print(cmd == .Connect ? "Successfully connected to \(targetDeviceName)" : "Successfully disconnected from \(targetDeviceName)")
        }
    }
    dispatchGroup.enter()
    if (cmd == .Connect) {
        if (option == .WiredConnection) {
            guard let cSidecarDisplayConfig = NSClassFromString("SidecarDisplayConfig") as? NSObject.Type else {
                fatalError("SidecarDisplayConfig class not found")
            }
            
            let deviceConfig = cSidecarDisplayConfig.init()
            let setTransportSelector = Selector(("setTransport:"))
            guard deviceConfig.responds(to: setTransportSelector) else {
                 fatalError("SidecarDisplayConfig does not respond to setTransport:")
            }
            let setTransportIMP = deviceConfig.method(for: setTransportSelector)
            let setTransport = unsafeBitCast(setTransportIMP, to:(@convention(c)(Any?, Selector, Int64)->Void).self)
            setTransport(deviceConfig, setTransportSelector, 2)
            
            let connectSelector = Selector(("connectToDevice:withConfig:completion:"))
            guard manager.responds(to: connectSelector) else {
                fatalError("SidecarDisplayManager does not respond to connectToDevice:withConfig:completion:")
            }
            let connectIMP = manager.method(for: connectSelector)
            let connect = unsafeBitCast(connectIMP,to:(@convention(c)(Any?,Selector,Any?,Any?,Any?)->Void).self)
            connect(manager,connectSelector, targetDevice, deviceConfig, closure)
        } else {
             let connectSelector = Selector(("connectToDevice:completion:"))
             guard manager.responds(to: connectSelector) else {
                 fatalError("SidecarDisplayManager does not respond to connectToDevice:completion:")
             }
            _ = manager.perform(connectSelector, with: targetDevice, with: closure)
        }
    } else {
        assert(cmd == .Disconnect)
        let disconnectSelector = Selector(("disconnectFromDevice:completion:"))
        guard manager.responds(to: disconnectSelector) else {
            fatalError("SidecarDisplayManager does not respond to disconnectFromDevice:completion:")
        }
        _ = manager.perform(disconnectSelector, with: targetDevice, with: closure)
    }
    dispatchGroup.wait()
    
} else if cmd == .Toggle {
    if devices.isEmpty {
        print("No sidecar capable devices detected to connect to.")
        exit(2)
    }

    let firstDevice = devices[0]
    let firstDeviceName = firstDevice.perform(Selector(("name")))?.takeUnretainedValue() as! String
    print("Found device: \(firstDeviceName)")

    print("Attempting to disconnect (in case already connected)...")
    let disconnectDispatchGroup = DispatchGroup()
    var disconnectError: NSError? = nil
    let disconnectClosure: @convention(block) (_ e: NSError?) -> Void = { e in
        disconnectError = e
        if e == nil {
             print("Successfully disconnected from \(firstDeviceName)")
        } else {
             print("Disconnection attempt finished (may not have been connected).")
        }
        disconnectDispatchGroup.leave()
    }

    disconnectDispatchGroup.enter()
    let disconnectSelector = Selector(("disconnectFromDevice:completion:"))
     if manager.responds(to: disconnectSelector) {
        _ = manager.perform(disconnectSelector, with: firstDevice, with: disconnectClosure)
     } else {
         print("Warning: Cannot find disconnect method, proceeding to connect.")
         disconnectDispatchGroup.leave()
     }
    disconnectDispatchGroup.wait()

    if disconnectError == nil {
        print("Toggle: Successfully disconnected.")
        exit(0)
    } else {
        print("Toggle: Not connected or disconnect failed. Attempting connection...")

        print("Attempting to connect to \(firstDeviceName)...")
        let connectDispatchGroup = DispatchGroup()
        var connectError: NSError? = nil
        let connectClosure: @convention(block) (_ e: NSError?) -> Void = { e in
            connectError = e
            if e == nil {
                 print("Successfully connected to \(firstDeviceName)")
            } else {
                 print("Error during connection: \(e!.localizedDescription)")
                 if let underlyingError = e!.userInfo[NSUnderlyingErrorKey] as? NSError {
                      print("Underlying Error: \(underlyingError.localizedDescription)")
                 }
            }
            connectDispatchGroup.leave()
        }

        connectDispatchGroup.enter()
        let connectSelector = Selector(("connectToDevice:completion:"))
        if manager.responds(to: connectSelector) {
             _ = manager.perform(connectSelector, with: firstDevice, with: connectClosure)
        } else {
             print("Error: Cannot find connect method.")
             connectError = NSError(domain: "SidecarLauncher", code: 4, userInfo: [NSLocalizedDescriptionKey: "Connect method not found on SidecarDisplayManager"])
             connectDispatchGroup.leave()
        }
        connectDispatchGroup.wait()

        if connectError != nil {
            exit(4)
        } else {
            exit(0)
        }
    }
} else {
    let deviceNames = devices.map{$0.perform(Selector(("name")))?.takeUnretainedValue() as! String}
    for deviceName in deviceNames {
        print(deviceName)
    }
}
