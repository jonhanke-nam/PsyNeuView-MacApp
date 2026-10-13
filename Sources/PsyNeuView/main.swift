import AppKit

// PsyNeuView Mac App — menubar launcher for PsyNeuView
// Manages the backend (FastAPI/uvicorn) and frontend (Vite) processes

@MainActor
func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Show in Dock like a normal app
    app.setActivationPolicy(.regular)

    app.run()
}

MainActor.assumeIsolated {
    runApp()
}
