-- Registration only. Each reader/commit independently enforces default-off gate,
-- current Core session and (for writes) exact released Weapons reservation.
assert(NativeUtilityEquipment and NativeUtilityExportInstaller,'Native utility modules missing')
NativeUtilityExportInstaller(NativeUtilityEquipment)
