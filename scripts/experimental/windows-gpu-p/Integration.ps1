# These are REQUIRED integration boundaries, not optional customization hooks.
# The reference export deliberately cannot authorize live operations.
# See README.md for the contract each implementation must satisfy.
function Assert-CgGuestAdmin {
    throw 'Integration required: validate the exact guest administrative identity.'
}
function Get-CgGuestRunPath($Plan) {
    throw 'Integration required: bind the guest transaction root to the exact VM and run.'
}
function Get-CgHostDiagnosticRoot {
    throw 'Integration required: provide a private owned DISM diagnostic directory.'
}
function Assert-CgPlanCurrent($Plan,[ValidateSet('Any','Off','Running')][string]$State='Any') {
    throw 'Integration required: validate frozen plan, VM, VHD, driver and lifecycle identity.'
}
function Assert-CgQuiet($Plan) {
    throw 'Integration required: acquire Cage maintenance ownership and verify actual shutdown.'
}
function Read-CgHostJournal($Plan) {
    throw 'Integration required: read the private plan-bound host transaction journal.'
}
function Save-CgHostJournal($Plan,$Journal) {
    throw 'Integration required: durably save the private plan-bound host transaction journal.'
}
