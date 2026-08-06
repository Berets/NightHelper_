import UIKit
import Flutter
import AVFoundation

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    
    // Inizializzazione del MethodChannel per l'hardware IR
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let irChannel = FlutterMethodChannel(name: "com.pediatric.scanner/ir",
                                              binaryMessenger: controller.binaryMessenger)
    
    irChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      
      switch call.method {
      case "checkIRSupport":
          self.checkIRSupport(result: result)
      case "enableIRMode":
          self.enableIRMode(result: result)
      default:
          result(FlutterMethodNotImplemented)
      }
    })
      
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
    
  private func checkIRSupport(result: FlutterResult) {
      if #available(iOS 11.1, *) {
          // Ricerca specifica del sensore TrueDepth (usato dal FaceID, ha un proiettore/lettore IR)
          let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera], mediaType: .video, position: .front)
          if discoverySession.devices.first != nil {
              result(true)
          } else {
              result(false)
          }
      } else {
          result(false) // Non supportato sotto iOS 11.1
      }
  }

  private func enableIRMode(result: FlutterResult) {
      if #available(iOS 11.1, *) {
          let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera], mediaType: .video, position: .front)
          
          guard let device = discoverySession.devices.first else {
              result(FlutterError(code: "UNAVAILABLE", message: "Fotocamera TrueDepth non disponibile sul dispositivo.", details: nil))
              return
          }
          
          do {
              try device.lockForConfiguration()
              
              // 1. Forza l'esposizione massima per far entrare quanta più luce IR possibile
              let maxDuration = device.activeFormat.maxExposureDuration
              let maxISO = device.activeFormat.maxISO
              device.setExposureModeCustom(duration: maxDuration, iso: maxISO, completionHandler: nil)
              
              // 2. Modifica il White Balance per intercettare gli infrarossi a 940nm
              // Valori fittizi "estremi" per tentare di forzare la sensibilità sul canale rosso/IR
              let tempAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: 9000, tint: 0)
              let wbGains = device.deviceWhiteBalanceGains(for: tempAndTint)
              let normalizedGains = self.normalizeGains(gains: wbGains, device: device)
              
              device.setWhiteBalanceModeLocked(with: normalizedGains, completionHandler: nil)
              
              device.unlockForConfiguration()
              result(true)
          } catch {
              result(FlutterError(code: "CONFIG_ERROR", message: "Errore durante il blocco del dispositivo hardware.", details: error.localizedDescription))
          }
      } else {
          result(FlutterError(code: "UNAVAILABLE", message: "Richiede almeno iOS 11.1.", details: nil))
      }
  }
  
  // Normalizza il guadagno della fotocamera per evitare crash dovuti a valori fuori dal range consentito
  private func normalizeGains(gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
      var g = gains
      g.redGain = max(1.0, min(g.redGain, device.maxWhiteBalanceGain))
      g.greenGain = max(1.0, min(g.greenGain, device.maxWhiteBalanceGain))
      g.blueGain = max(1.0, min(g.blueGain, device.maxWhiteBalanceGain))
      return g
  }
}
