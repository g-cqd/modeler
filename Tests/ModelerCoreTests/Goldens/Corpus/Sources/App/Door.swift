enum DoorState {
    case open
    case closed
    case locked
}

final class Door {
    var state: DoorState = .closed

    func open() {
        if state == .closed { state = .open }
    }

    func close() {
        if state == .open { state = .closed }
    }

    func lock() {
        if state == .closed { state = .locked }
    }
}
