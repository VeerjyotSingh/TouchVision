import Foundation
import AVFoundation
import CoreImage
import UIKit
import PhotosUI
import CoreImage
import Photos
import CoreGraphics
import Swifter
import CoreBluetooth

protocol CaptureDataReceiver: AnyObject {
    func onNewData(capturedData: CameraCapturedData)
    func onNewPhotoData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject, UIImagePickerControllerDelegate {
    
    

    
    enum ConfigurationError: Error {
        case lidarDeviceUnavailable
        case requiredFormatUnavailable
    }
    private let widthArray = 10
    private let heightArray = 100
    private let preferredWidthResolution = 1920
    
    private let videoQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoQueue", qos: .userInteractive)
    
    private(set) var captureSession: AVCaptureSession!
    
    private var photoOutput: AVCapturePhotoOutput!
    private var photo: AVCapturePhoto!
    private var depthDataOutput: AVCaptureDepthDataOutput!
    private var videoDataOutput: AVCaptureVideoDataOutput!
    private var outputVideoSync: AVCaptureDataOutputSynchronizer!
    private var textureCache: CVMetalTextureCache!
    private var depthphoto: UIImage!
    private var cgImag: CGImage!
    
    weak var delegate: CaptureDataReceiver?
    
    var isFilteringEnabled = true {
        didSet {
            depthDataOutput.isFilteringEnabled = isFilteringEnabled
        }
    }
    
    override init() {
        
        // Create a texture cache to hold sample buffer textures.
        CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                  nil,
                                  MetalEnvironment.shared.metalDevice,
                                  nil,
                                  &textureCache)
        
        super.init()
        
        do {
            try setupSession()
        } catch {
            fatalError("Unable to configure the capture session.")
        }
    }
    
    private func setupSession() throws {
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .inputPriority
        
        // Configure the capture session.
        captureSession.beginConfiguration()
        
        try setupCaptureInput()
        setupCaptureOutputs()
        
        // Finalize the capture session configuration.
        captureSession.commitConfiguration()
    }
    
    private func setupCaptureInput() throws {
        // Look up the LiDAR camera.
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw ConfigurationError.lidarDeviceUnavailable
        }
        
        // Find a match that outputs video data in the format the app's custom Metal views require.
        guard let format = (device.formats.last { format in
            format.formatDescription.dimensions.width == preferredWidthResolution &&
            format.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            !format.isVideoBinned &&
            !format.supportedDepthDataFormats.isEmpty
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Find a match that outputs depth data in the format the app's custom Metal views require.
        guard let depthFormat = (format.supportedDepthDataFormats.last { depthFormat in
            depthFormat.formatDescription.mediaSubType.rawValue == kCVPixelFormatType_DepthFloat16
        }) else {
            throw ConfigurationError.requiredFormatUnavailable
        }
        
        // Begin the device configuration.
        try device.lockForConfiguration()
        
        // Configure the device and depth formats.
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        
        // Finish the device configuration.
        device.unlockForConfiguration()
        
        print("Selected video format: \(device.activeFormat)")
        print("Selected depth format: \(String(describing: device.activeDepthDataFormat))")
        
        // Add a device input to the capture session.
        let deviceInput = try AVCaptureDeviceInput(device: device)
        captureSession.addInput(deviceInput)
    }
    
    private func setupCaptureOutputs() {
        // Create an object to output video sample buffers.
        videoDataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(videoDataOutput)
        
        // Create an object to output depth data.
        depthDataOutput = AVCaptureDepthDataOutput()
        depthDataOutput.isFilteringEnabled = isFilteringEnabled
        captureSession.addOutput(depthDataOutput)
        
        // Create an object to synchronize the delivery of depth and video data.
        outputVideoSync = AVCaptureDataOutputSynchronizer(dataOutputs: [depthDataOutput, videoDataOutput])
        outputVideoSync.setDelegate(self, queue: videoQueue)
        
        // Enable camera intrinsics matrix delivery.
        guard let outputConnection = videoDataOutput.connection(with: .video) else { return }
        if outputConnection.isCameraIntrinsicMatrixDeliverySupported {
            outputConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
        
        // Create an object to output photos.
        photoOutput = AVCapturePhotoOutput()
        photoOutput.maxPhotoQualityPrioritization = .quality
        captureSession.addOutput(photoOutput)
        
        // Enable delivery of depth data after adding the output to the capture session.
        photoOutput.isDepthDataDeliveryEnabled = true
    }
    
    func startStream() {
        captureSession.startRunning()
    }
    
    func stopStream() {
        captureSession.stopRunning()
    }
}

// MARK: Output Synchronizer Delegate
extension CameraController: AVCaptureDataOutputSynchronizerDelegate {
    
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        // Retrieve the synchronized depth and sample buffer container objects.
        guard let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
              let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData else { return }
        
        guard let pixelBuffer = syncedVideoData.sampleBuffer.imageBuffer,
              let cameraCalibrationData = syncedDepthData.depthData.cameraCalibrationData else { return }
        
        // Package the captured data.
        let data = CameraCapturedData(depth: syncedDepthData.depthData.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewData(capturedData: data)
    }
}

// MARK: Photo Capture Delegate
extension CameraController: AVCapturePhotoCaptureDelegate {
    
    func capturePhoto() {
        var photoSettings: AVCapturePhotoSettings
        if  photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            photoSettings = AVCapturePhotoSettings(format: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ])
        } else {
            photoSettings = AVCapturePhotoSettings()
        }
        
        // Capture depth data with this photo capture.
        photoSettings.isDepthDataDeliveryEnabled = true
        photoSettings.embedsDepthDataInPhoto = true
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        // Retrieve the image and depth data.
        guard let pixelBuffer = photo.pixelBuffer,
              let depthData = photo.depthData,
              let cameraCalibrationData = depthData.cameraCalibrationData else { return }
        
        // Stop the stream until the user returns to streaming mode.
        stopStream()
        
        // Convert the depth data to the expected format.
        let convertedDepth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        
        // Package the captured data.
        let data = CameraCapturedData(depth: convertedDepth.depthDataMap.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                                      colorY: pixelBuffer.texture(withFormat: .r8Unorm, planeIndex: 0, addToCache: textureCache),
                                      colorCbCr: pixelBuffer.texture(withFormat: .rg8Unorm, planeIndex: 1, addToCache: textureCache),
                                      cameraIntrinsics: cameraCalibrationData.intrinsicMatrix,
                                      cameraReferenceDimensions: cameraCalibrationData.intrinsicMatrixReferenceDimensions)
        
        delegate?.onNewPhotoData(capturedData: data)
        createPhotoFile(photo: photo)
        print("Image captured.")
        
        if let imageData = photo.fileDataRepresentation() {
            if let uiImage = UIImage(data: imageData){
                UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil);
            }
        }
        if let grayscaleImage = createGrayscaleImageFromAVDepthData(depthData) {
            // Save the grayscale image to the Photos library
            PHPhotoLibrary.shared().performChanges {
                if let imageData = grayscaleImage.pngData() {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    creationRequest.addResource(with: .photo, data: imageData, options: nil)
                }
            } completionHandler: { success, error in
                if success {
                    print("Depth data saved to Photos successfully.")
                } else {
                    print("Error saving depth data to Photos: \(error?.localizedDescription ?? "")")
                }
            }
        }
        func createGrayscaleImageFromAVDepthData(_ depthData: AVDepthData) -> UIImage? {
            // Retrieve the depth data as a CVPixelBuffer
            let depthPixelBuffer = depthData.depthDataMap
            
            // Check if the depthPixelBuffer is not nil
            if depthPixelBuffer != nil {
                let ciImage = CIImage(cvPixelBuffer: depthPixelBuffer)
                let filter = CIFilter(name: "CIColorControls")
                filter?.setValue(ciImage, forKey: kCIInputImageKey)
                filter?.setValue(1.0, forKey: kCIInputContrastKey)
                if let outputImage = filter?.outputImage {
                    let context = CIContext()
                    if let cgImage = context.createCGImage(outputImage, from: outputImage.extent) {
                        cgImag = cgImage
                        depthphoto = UIImage(cgImage: cgImage)
                        let newSize = CGSize(width: widthArray, height: heightArray)
                        
                        // Create a context for the resized image
                        if let context = CGContext(
                            data: nil,
                            width: Int(newSize.width),
                            height: Int(newSize.height),
                            bitsPerComponent: 8,
                            bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).rawValue
                        ) {
                            
                            // Draw the original image into the context to create the resized grayscale version
                            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newSize.width, height: newSize.height))
                            
                            // Create a 2D array from the resized grayscale pixel data
                            if let data = context.data {
                                let buffer = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: Int(newSize.width) * Int(newSize.height)), count: Int(newSize.width) * Int(newSize.height))
                                var resizedGrayscaleArray: [[UInt8]] = []
                                
                                for i in 0..<Int(newSize.height) {
                                    let row = Array(buffer[i * Int(newSize.width)..<(i + 1) * Int(newSize.width)])
                                    resizedGrayscaleArray.append(row)
                                }
                                
                                // Now, resizedGrayscaleArray contains the 2D array of grayscale pixel values from the resized image.
                                print(resizedGrayscaleArray) // Start the server on a specific port
                            }
                        }
                        return UIImage(cgImage: cgImage)
                    }
                }
            }
            return nil // Return nil in case of processing failure or if depthPixelBuffer is nil
        }
    }
}
extension CameraController {
    func setUpPhotoOutput() {
        photoOutput = AVCapturePhotoOutput()
        photoOutput.maxPhotoQualityPrioritization = .quality
        self.captureSession.addOutput(photoOutput)
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
    }
    func createPhotoFile(
        photo: AVCapturePhoto
    ) {
        let customizer = PhotoDataCustomizer()
        let mainImageData = photo.fileDataRepresentation(with: customizer)!
        // note mainImageData should have embeded depth data, but...
        let imageSource = CGImageSourceCreateWithData(mainImageData as CFData, nil)!
        let depthDataDict = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            imageSource,
            0,
            kCGImageAuxiliaryDataTypeDepth
        )
        let disparityDataDict = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            imageSource,
            0,
            kCGImageAuxiliaryDataTypeDisparity
        )
        print("depthDataDict", depthDataDict ?? "nil")
        print("disparityDataDict", disparityDataDict ?? "nil")
        // ... both depthDataDict and disparityDataDict come out as nil
    }
    func createGrayscaleArray(from cgImage: CGImage) -> [[UInt8]]? {
        let width = cgImage.width
        let height = cgImage.height
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).rawValue
        ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        if let data = context.data {
            let buffer = UnsafeBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: width * height), count: width * height)
            let dataArray = Array(buffer)
            var resultArray: [[UInt8]] = []
            
            for i in 0..<height {
                let row = Array(dataArray[i * width..<(i + 1) * width])
                resultArray.append(row)
            }
            print(resultArray)
            return resultArray
        } else {
            return nil
        }
    }
}

class PhotoDataCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    func replacementDepthData(for photo: AVCapturePhoto) -> AVDepthData? {
        let depthData = photo.depthData?.converting(toDepthDataType: kCVPixelFormatType_DepthFloat16)
        return depthData
    }
    
}




class BLueManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate,ObservableObject {
    var centralManager: CBCentralManager!
    var peripheral: CBPeripheral!
    var targetCharacteristic: CBCharacteristic? // Add this property

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        if peripheral.name == "MacBook Air" {
            self.peripheral = peripheral
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let characteristics = service.characteristics {
            for characteristic in characteristics {
                if characteristic.uuid == CBUUID(string: "F3737FEA-D4C3-5131-A518-AFD42CA05DB8") {
                    targetCharacteristic = characteristic // Store the target characteristic
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value {
            let value = String(data: data, encoding: .utf8)
            print("Received Value: \(value ?? "N/A")")
        }
    }

    // Method to send data
    func sendData(data: Data) {
        if let characteristic = targetCharacteristic {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            print("data sent")
        }
    }
    func startBluetooth() {
            if centralManager.state == .poweredOn {
                // Replace "YourPeripheralName" with the name of your peripheral device
                let peripheralName = "YourPeripheralName"
                
                // Scan for peripherals with the specified name
                centralManager.scanForPeripherals(withServices: nil, options: nil)
            } else {
                print("Bluetooth is not powered on.")
            }
        }
}
