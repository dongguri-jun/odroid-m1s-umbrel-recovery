import "./old-entry.js"

globalThis.__shutdownUiFixtureEvents = (globalThis.__shutdownUiFixtureEvents || []).concat("settings-content")
document.body.dataset.shutdownUi = "ready"
