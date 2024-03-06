//
//  PacketTunnelProvider.swift
//  NetExt
//
//  Created by Gabriele Mondada on 02.03.2024.
//

import NetworkExtension
import OSLog

private let log = OSLog(subsystem: "ch.ijk.NetExt", category: "general")

class PacketTunnelProvider: NEPacketTunnelProvider {

    private var dataProcessingTask: Task<Void, Never>?

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        os_log("tunnel start", log: log)

        let ipv4Settings = NEIPv4Settings(addresses: ["192.168.123.1"], subnetMasks: ["255.255.255.255"])
        ipv4Settings.includedRoutes = [NEIPv4Route(destinationAddress: "192.168.123.0", subnetMask: "255.255.255.0")]

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "1.1.1.1") // we need to provide a remote address but it's currenlty not used
        settings.ipv4Settings = ipv4Settings

        setTunnelNetworkSettings(settings, completionHandler: { error in
            if let error {
                os_log("tunnel start error=%{public}@", log: log, String(describing: error))
            } else {
                self.startDataProcessing()
            }
            completionHandler(error)
        })
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("tunnel stop", log: log)
        stopDataProcessing()
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        os_log("tunnel app message", log: log)
        if let handler = completionHandler {
            handler(messageData)
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        os_log("tunnel sleep", log: log)
        completionHandler()
    }
    
    override func wake() {
        os_log("tunnel wake", log: log)
    }

    private func startDataProcessing() {
        dataProcessingTask = Task.detached {
            while !Task.isCancelled {
                let packets = await self.packetFlow.readPacketObjects()
                for packet in packets {
                    let consumed = self.processIPPacket(packet)
                    if !consumed {
                        var hex = ""
                        for byte in packet.data {
                            if !hex.isEmpty {
                                hex += " "
                            }
                            hex += String(format: "%02X", Int(byte))
                        }
                        os_log("tunnel data in: family=%{public}d data=[%{public}@]", log: log, Int(packet.protocolFamily), hex)
                    }
                }
            }
        }
    }

    private func stopDataProcessing() {
        dataProcessingTask?.cancel()
        dataProcessingTask = nil
    }

    private func processIPPacket(_ packet: NEPacket) -> Bool {
        let data = packet.data
        guard packet.protocolFamily == AF_INET else {
            // just supporting IPv4 now
            return false
        }
        guard data.count >= 20 else {
            // no space for an IP header
            return false
        }
        let ipVersion = Int(data[0] >> 4)
        guard ipVersion == 4 else {
            // just supporting IPv4 now
            return false
        }
        let headerSize = 4 * Int(data[0] & 0x0f)
        guard data.count >= headerSize else {
            // no space for the full IP header
            return false
        }
        guard calculateIPChecksum(data.subdata(in: 0..<headerSize)) == 0 else {
            // bad checksum
            return false
        }

        // TODO: we could make additional verifications here, or relax existing one if we have no reason to expect malformed packets from the OS

        let ipProtocol = data[9]
        switch IPProtocol(rawValue: ipProtocol) {
        case .ICMP:
            return self.processICMPPacket(packet, ipHeaderSize: headerSize)
        default:
            return false
        }
    }

    private func processICMPPacket(_ packet: NEPacket, ipHeaderSize: Int) -> Bool {
        let data = packet.data
        guard data.count >= ipHeaderSize + 4 else {
            // no space for an ICMP header
            return false
        }
        guard calculateIPChecksum(data.subdata(in: ipHeaderSize..<data.count)) == 0 else {
            // bad checksum
            return false
        }
        let type = data[ipHeaderSize]
        switch ICMPType(rawValue: type) {
        case .pingRequest:
            return processPingRequest(packet, ipHeaderSize: ipHeaderSize);
        default:
            return false
        }
    }

    private func processPingRequest(_ packet: NEPacket, ipHeaderSize: Int) -> Bool {
        let data = packet.data
        guard data.count >= ipHeaderSize + 8 else {
            // no space for a echo/ping header
            return false
        }
        os_log("tunnel data in: ping request", log: log)
        os_log("tunnel data out: ping reply", log: log)
        let reply = generatePingReply(packet, ipHeaderSize: ipHeaderSize)
        self.packetFlow.writePacketObjects([reply])
        return true
    }

    private func generatePingReply(_ packet: NEPacket, ipHeaderSize: Int) -> NEPacket {
        var data = packet.data
        precondition(data.count >= ipHeaderSize + 8)

        /*
         * Here we build the simplest reply, by transforming the request.
         * We do not manage RR or timestamp options.
         * We recompute all checksums even though it's not needed or we could
         * update the existing one.
         */

        // set ICMP type
        data[ipHeaderSize] = ICMPType.pingReply.rawValue

        // swap source and destination IP addresses
        for i in 0 ..< 4 {
            let b = data[12 + i]
            data[12 + i] = data[16 + i]
            data[16 + i] = b
        }

        // compute checksums
        data[10] = 0
        data[11] = 0
        var cs1 = calculateIPChecksum(data.subdata(in: 0 ..< ipHeaderSize))
        let cs1Data = Data(bytes: &cs1, count: MemoryLayout<UInt16>.size)
        data[10] = cs1Data[0]
        data[11] = cs1Data[1]
        data[ipHeaderSize + 2] = 0
        data[ipHeaderSize + 3] = 0
        var cs2 = calculateIPChecksum(data.subdata(in: ipHeaderSize ..< data.count))
        let cs2Data = Data(bytes: &cs2, count: MemoryLayout<UInt16>.size)
        data[ipHeaderSize + 2] = cs2Data[0]
        data[ipHeaderSize + 3] = cs2Data[1]

        return NEPacket(data: data, protocolFamily: packet.protocolFamily)
    }

    /// returned checksum is in network byte order
    private func calculateIPChecksum(_ data: Data) -> UInt16 {
        var checksum: UInt32 = 0

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var index = 0

            // sum
            while index < buffer.count - 1 {
                let d = buffer.load(fromByteOffset: index, as: UInt16.self)
                checksum += UInt32(d)
                index += 2
            }

            // add left-over byte, if any
            if index < buffer.count {
                // we want the remaining byte to be the first in a 2-byte value
                let d = UInt16(buffer.load(fromByteOffset: index, as: UInt8.self)).littleEndian
                checksum += UInt32(d)
                index += 1
            }

            assert(index == buffer.count)
        }

        // fold 32-bit sum to 16 bits
        while (checksum >> 16) != 0 {
            checksum = (checksum & 0xFFFF) + (checksum >> 16)
        }

        // take one's complement of the final sum
        let result = UInt16(~checksum & 0xFFFF)

        return result
    }
}

private enum IPProtocol: UInt8 {
    case ICMP = 1
    case TCP = 6
    case UDP = 17
    case ICMPv6 = 58
}

private enum ICMPType: UInt8 {
    case pingReply = 0
    case pingRequest = 8
}
