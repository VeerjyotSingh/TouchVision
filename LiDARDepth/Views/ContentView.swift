import SwiftUI
import AVFoundation
import MetalKit
import Metal
import CoreBluetooth

struct ContentView: View{
    func dataFromHexString(_ hexString: String) -> Data? {
        var hex = hexString
        hex = hex.replacingOccurrences(of: " ", with: "")

        var data = Data(capacity: hex.count / 2)
        var startIndex = hex.startIndex

        while startIndex < hex.endIndex {
            let endIndex = hex.index(startIndex, offsetBy: 2)
            if let byte = UInt8(hex[startIndex..<endIndex], radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            startIndex = endIndex
        }
        return data
    }
    @StateObject var bluetoothManager = BLueManager()
    @StateObject private var manager = CameraManager()
    @State private var maxDepth = Float(5.0)
    @State private var minDepth = Float(0.0)
    @State private var scaleMovement = Float(1.0)
    @State private var centralManager: CBCentralManager!
    @State private var peripheral: CBPeripheral?
    @State private var characteristic: CBCharacteristic?
    let maxRangeDepth = Float(10)
    let minRangeDepth = Float(0)
    @State private var opacity = Float(0.5)
    var body: some View {
        
        if manager.dataAvailable {
            VStack {
                HStack {
                Button {
                    manager.processingCapturedResult ? manager.resumeStream() : manager.startPhotoCapture()
                    bluetoothManager.startBluetooth()
                    if let data = "myString".data(using: .utf8) {
                        print(data)
                        bluetoothManager.sendData(data: data)
                        print("data sent")
                    } else {
                        print("String to Data conversion failed.")
                    }
                    // Replace this string with your actual data
                    // Replace this string with your actual data
                    let hexString = "02 01 1A 02 0A 0C 0B FF 4C 00 10 06 77 1D 5C AE F0 18"

                    // Remove spaces and convert to Data
                    let hexWithoutSpaces = hexString.replacingOccurrences(of: " ", with: "")
                    if let data = dataFromHexString(hexWithoutSpaces) {
                        if let text = String(data: data, encoding: .utf8) {
                            print("Text data: \(text)")
                        }
                    }

                    
                } label: {
                    Image(systemName: manager.processingCapturedResult ? "play.circle" : "camera.circle")
                        .font(.largeTitle)
                }
                
                Text("Depth Filtering")
                Toggle("Depth Filtering", isOn: $manager.isFilteringDepth).labelsHidden()
                Spacer()
            }
                SliderDepthBoundaryView(val: $maxDepth, label: "Max Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
                SliderDepthBoundaryView(val: $minDepth, label: "Min Depth", minVal: minRangeDepth, maxVal: maxRangeDepth)
                SliderDepthBoundaryView(val: $opacity, label: "Opacity", minVal: 0, maxVal: 1)
                ZStack {
                    MetalTextureViewColor(
                        rotationAngle: rotationAngle,
                        capturedData: manager.capturedData
                    )
                    MetalTextureDepthView(
                        rotationAngle: rotationAngle,
                        maxDepth: $maxDepth,
                        minDepth: $minDepth,
                        capturedData: manager.capturedData
                    )
                        .opacity(Double(opacity))
                        .onAppear {
                                    }
                }
            }
        }
        
        
    }
    
    
    
    func calcAspect(orientation: UIImage.Orientation, texture: MTLTexture?) -> CGFloat {
        guard let texture = texture else { return 1 }
        switch orientation {
        case .up:
            return CGFloat(texture.width) / CGFloat(texture.height)
        case .down:
            return CGFloat(texture.width) / CGFloat(texture.height)
        case .left:
            return  CGFloat(texture.height) / CGFloat(texture.width)
        case .right:
            return  CGFloat(texture.height) / CGFloat(texture.width)
        default:
            return CGFloat(texture.width) / CGFloat(texture.height)
        }
    }
    
    var rotationAngle: Double {
        var angle = 0.0
        switch viewOrientation {
        
        case .up:
            angle = -Double.pi / 2
        case .down:
            angle = Double.pi / 2
        case .left:
            angle = Double.pi
        case .right:
            angle = 0
        default:
            angle = 0
        }
        return angle
    }

    var viewOrientation: UIImage.Orientation {
        var result = UIImage.Orientation.up
       
        guard let currentWindowScene = UIApplication.shared.connectedScenes.first(
            where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return result }
        
        let interfaceOrientation = currentWindowScene.interfaceOrientation
        switch interfaceOrientation {
        case .portrait:
            result = .right
        case .portraitUpsideDown:
            result = .left
        case .landscapeLeft:
            result = .down
        case .landscapeRight:
            result = .up
        default:
            result = .up
        }
            
        return result
    }
}


struct SliderDepthBoundaryView: View {
    @Binding var val: Float
    var label: String
    var minVal: Float
    var maxVal: Float
    let stepsCount = Float(200.0)
    var body: some View {
        HStack {
            Text(String(format: " %@: %.2f", label, val))
            Slider(
                value: $val,
                in: minVal...maxVal,
                step: (maxVal - minVal) / stepsCount
            ) {
            } minimumValueLabel: {
                Text(String(minVal))
            } maximumValueLabel: {
                Text(String(maxVal))
            }
        }
    }
}

