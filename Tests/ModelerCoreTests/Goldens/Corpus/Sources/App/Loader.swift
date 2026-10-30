actor Loader {
    var phase = 0
    var count = 0

    func load() async {
        guard phase == 0 else { return }
        await fetch()
        phase = 1
    }

    func reload() async {
        guard phase == 1 else { return }
        await fetch()
        guard phase == 1 else { return }
        phase = 2
    }

    func fetch() async {}
}
