globalThis.__shutdownUiFixtureEvents = (globalThis.__shutdownUiFixtureEvents || []).concat("entry")

const he = "shutting-down"
const v = false
const ce = { isError: false, failureCount: 0 }
const b = () => {}
const S = () => {}
const Kh = 1
he==="shutting-down"&&!v&&(ce.isError||ce.failureCount>0)&&(b(!0),setTimeout(()=>S(!0),30*Kh))

import("./settings-content.js")
