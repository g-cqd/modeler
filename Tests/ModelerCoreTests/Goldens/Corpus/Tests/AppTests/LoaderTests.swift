import Testing

actor Probe {
    var seen = false

    func run() async {
        guard !seen else { return }
        await Task.yield()
        seen = true
    }
}
