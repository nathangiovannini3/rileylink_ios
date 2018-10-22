//
//  OmnipodPumpManager.swift
//  OmniKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import HealthKit
import LoopKit
import RileyLinkKit
import RileyLinkBLEKit
import os.log

public protocol ReservoirVolumeObserver: AnyObject {
    func reservoirVolumeDidChange(_ units: Double, at validTime: Date, level: Double?)
}

public class OmnipodPumpManager: RileyLinkPumpManager, PumpManager {

    public var pumpRecordsBasalProfileStartEvents = false
    
    public var pumpReservoirCapacity: Double = 200
    
    public var pumpTimeZone: TimeZone {
        return state.podState.timeZone
    }
    
    private var lastPumpDataReportDate: Date?
    
    private var reservoirVolumeObservers: NSHashTable<AnyObject>
    
    public func addReservoirVolumeObserver(_ observer: ReservoirVolumeObserver) {
        reservoirVolumeObservers.add(observer)
    }
    
    public func assertCurrentPumpData() {
        
        let pumpStatusAgeTolerance = TimeInterval(minutes: 4)
        
        queue.async {
            
            guard (self.lastPumpDataReportDate ?? .distantPast).timeIntervalSinceNow < -pumpStatusAgeTolerance else {
                return
            }
            
            let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
            self.podComms.runSession(withName: "Get status for currentPumpData assertion", using: rileyLinkSelector) { (result) in
                do {
                    switch result {
                    case .success(let session):
                        let status = try session.getStatus()
                        
                        session.storeFinalizeDoses(deliveryStatus: status.deliveryStatus, storageHandler: { (doses) -> Bool in
                            return self.store(doses: doses)
                        })

                        if let reservoirLevel = status.reservoirLevel {
                            let semaphore = DispatchSemaphore(value: 0)
                            self.pumpManagerDelegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: Date()) { (_) in
                                semaphore.signal()
                            }
                            semaphore.wait()
                        }
                        self.log.info("Recommending Loop")
                        self.pumpManagerDelegate?.pumpManagerRecommendsLoop(self)
                    case .failure(let error):
                        throw error
                    }
                } catch let error {
                    self.log.error("Failed to fetch pump status: %{public}@", String(describing: error))
                }
            }
        }
    }
    
    public func suspendDelivery(completion: @escaping (PumpManagerResult<Bool>) -> Void) {
        let rileyLinkSelector = rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Suspend", using: rileyLinkSelector) { (result) in
            
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(PumpManagerResult.failure(error))
                return
            }
            
            do {
                let status = try session.cancelDelivery(deliveryType: .all, beepType: .noBeep)
                completion(PumpManagerResult.success(status.deliveryStatus == .suspended))
                self.pumpManagerDelegate?.pumpManager(self, didUpdateStatus: self.status)
            } catch (let error) {
                completion(PumpManagerResult.failure(error))
            }
        }
    }
    
    public func resumeDelivery(completion: @escaping (PumpManagerResult<Bool>) -> Void) {
        let rileyLinkSelector = rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Resume", using: rileyLinkSelector) { (result) in
            
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(PumpManagerResult.failure(error))
                return
            }
            
            do {
                let status = try session.resumeBasal()
                completion(PumpManagerResult.success(status.deliveryStatus != .suspended))
                self.pumpManagerDelegate?.pumpManager(self, didUpdateStatus: self.status)
            } catch (let error) {
                completion(PumpManagerResult.failure(error))
            }
        }
    }
    
    public func enactBolus(units: Double, at startDate: Date, willRequest: @escaping (Double, Date) -> Void, completion: @escaping (Error?) -> Void) {
        
        // Round to nearest supported volume
        let enactUnits = round(units / podPulseSize) * podPulseSize
        
        let rileyLinkSelector = rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Bolus", using: rileyLinkSelector) { (result) in
            
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(SetBolusError.certain(error))
                return
            }
            
            var podStatus: StatusResponse
            
            do {
                podStatus = try session.getStatus()
            } catch let error {
                completion(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error)))
                return
            }
            
            // If pod suspended, resume basal before bolusing
            if podStatus.deliveryStatus == .suspended {
                do {
                    podStatus = try session.resumeBasal()
                } catch let error {
                    completion(SetBolusError.certain(error as? PodCommsError ?? PodCommsError.commsError(error: error)))
                    return
                }
                self.pumpManagerDelegate?.pumpManager(self, didUpdateStatus: self.status)
            }
            
            guard !podStatus.deliveryStatus.bolusing else {
                completion(SetBolusError.certain(PodCommsError.unfinalizedBolus))
                return
            }
            
            session.storeFinalizeDoses(deliveryStatus: podStatus.deliveryStatus, storageHandler: { ( _ ) -> Bool in
                return false
            })
            
            willRequest(enactUnits, Date())
            
            let result = session.bolus(units: enactUnits)
            
            switch result {
            case .success:
                completion(nil)
            case .certainFailure(let error):
                completion(SetBolusError.certain(error))
            case .uncertainFailure(let error):
                completion(SetBolusError.uncertain(error))
            }
        }
    }
    
    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerResult<DoseEntry>) -> Void) {
        
        // Round to nearest supported rate
        let rate = round(unitsPerHour / podPulseSize) * podPulseSize
        
        let rileyLinkSelector = rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Enact Temp Basal", using: rileyLinkSelector) { (result) in
            self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(PumpManagerResult.failure(error))
                return
            }
            
            do {
                let podStatus = try session.getStatus()
                
                if podStatus.deliveryStatus == .suspended {
                    throw PodCommsError.podSuspended
                }
                
                if podStatus.deliveryStatus.tempBasalRunning {
                    let cancelStatus = try session.cancelDelivery(deliveryType: .tempBasal, beepType: .noBeep)

                    guard !cancelStatus.deliveryStatus.tempBasalRunning else {
                        throw PodCommsError.unfinalizedTempBasal
                    }
                }
                
                if duration < .ulpOfOne {
                    // 0 duration temp basals are used to cancel any existing temp basal
                    let cancelTime = Date()
                    let dose = DoseEntry(type: .basal, startDate: cancelTime, endDate: cancelTime, value: 0, unit: .unitsPerHour)
                    completion(PumpManagerResult.success(dose))
                } else {
                    let result = session.setTempBasal(rate: rate, duration: duration, confidenceReminder: false, programReminderInterval: 0)
                    let basalStart = Date()
                    let dose = DoseEntry(type: .basal, startDate: basalStart, endDate: basalStart.addingTimeInterval(duration), value: rate, unit: .unitsPerHour)
                    switch result {
                    case .success:
                        completion(PumpManagerResult.success(dose))
                    case .uncertainFailure(let error):
                        self.log.error("Temp basal uncertain error: %@", String(describing: error))
                        completion(PumpManagerResult.success(dose))
                    case .certainFailure(let error):
                        completion(PumpManagerResult.failure(error))
                    }
                }
            } catch let error {
                self.log.error("Error during temp basal: %@", String(describing: error))
                completion(PumpManagerResult.failure(error))
            }
        }
    }
    
    public func updateBLEHeartbeatPreference() {
        return
    }
    
    public static let managerIdentifier: String = "Omnipod"
    
    public init(state: OmnipodPumpManagerState, rileyLinkDeviceProvider: RileyLinkDeviceProvider, rileyLinkConnectionManager: RileyLinkConnectionManager? = nil) {
        self.state = state
        
        self.reservoirVolumeObservers = NSHashTable<AnyObject>.weakObjects()
        
        self.device = HKDevice(
            name: type(of: self).managerIdentifier,
            manufacturer: "Insulet",
            model: "Eros",
            hardwareVersion: nil,
            firmwareVersion: state.podState.piVersion,
            softwareVersion: String(OmniKitVersionNumber),
            localIdentifier: String(format:"%04X", state.podState.address),
            udiDeviceIdentifier: nil
        )
        
        super.init(rileyLinkDeviceProvider: rileyLinkDeviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)
        
        // Pod communication
        self.podComms = PodComms(podState: state.podState, delegate: self)
    }

    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmnipodPumpManagerState(rawValue: rawState),
            let connectionManagerState = state.rileyLinkConnectionManagerState else
        {
            return nil
        }
        
        let rileyLinkConnectionManager = RileyLinkConnectionManager(state: connectionManagerState)
        
        self.init(state: state, rileyLinkDeviceProvider: rileyLinkConnectionManager.deviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)
        
        rileyLinkConnectionManager.delegate = self
    }
    
    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }
    
    override public var rileyLinkConnectionManagerState: RileyLinkConnectionManagerState? {
        get {
            return state.rileyLinkConnectionManagerState
        }
        set {
            state.rileyLinkConnectionManagerState = newValue
        }
    }

    // TODO: apply lock
    public private(set) var state: OmnipodPumpManagerState {
        didSet {
            pumpManagerDelegate?.pumpManagerDidUpdateState(self)
            if oldValue.podState.timeZone != state.podState.timeZone || oldValue.podState.suspended != state.podState.suspended {
                self.pumpManagerDelegate?.pumpManager(self, didUpdateStatus: status)
            }
            
            if oldValue.podState.lastInsulinMeasurements != state.podState.lastInsulinMeasurements,
                let lastInsulinMeasurements = state.podState.lastInsulinMeasurements,
                let reservoirVolume = lastInsulinMeasurements.reservoirVolume
            {
                for observer in (reservoirVolumeObservers.allObjects.compactMap { $0 as? ReservoirVolumeObserver }) {
                    let reservoirLevel = min(1, max(0, reservoirVolume / pumpReservoirCapacity))
                    observer.reservoirVolumeDidChange(reservoirVolume, at: lastInsulinMeasurements.validTime, level: reservoirLevel)
                }
            }

        }
    }
    
    public var device: HKDevice?
    
    public var status: PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.podState.timeZone,
            device: device!,
            pumpBatteryChargeRemaining: nil,
            isSuspended: state.podState.suspended,
            isBolusing: state.podState.unfinalizedBolus != nil)
    }

    public weak var pumpManagerDelegate: PumpManagerDelegate?
    
    public let log = OSLog(category: "OmnipodPumpManager")
    
    public static let localizedTitle = NSLocalizedString("Omnipod", comment: "Generic title of the omnipod pump manager")
    
    public var localizedTitle: String {
        return String(format: NSLocalizedString("Omnipod", comment: "Omnipod title"))
    }
    
    override public func deviceTimerDidTick(_ device: RileyLinkDevice) {
        self.pumpManagerDelegate?.pumpManagerBLEHeartbeatDidFire(self)
    }
    
    // MARK: - CustomDebugStringConvertible
    
    override public var debugDescription: String {
        return [
            "## OmnipodPumpManager",
            "state: \(state.debugDescription)",
            "",
            String(describing: podComms!),
            super.debugDescription,
            "",
            ].joined(separator: "\n")
    }
    
    // MARK: - Configuration
    
    // MARK: Pump
    
    public private(set) var podComms: PodComms!    
}

extension OmnipodPumpManager: PodCommsDelegate {
    
    public func store(doses: [UnfinalizedDose]) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        self.pumpManagerDelegate?.pumpManager(self, didReadPumpEvents: doses.map { NewPumpEvent($0) }, completion: { (error) in
            if let error = error {
                self.log.error("Error storing pod events: %@", String(describing: error))
            } else {
                self.log.error("Stored pod events: %@", String(describing: doses))
            }
            success = error == nil
            semaphore.signal()
        })
        semaphore.wait()
        
        if success {
            self.lastPumpDataReportDate = Date()
        }
        return success
    }
    
    public func podComms(_ podComms: PodComms, didChange state: PodState) {
        self.state.podState = state
    }
}

