# MSI lifecycle support

| File | Purpose |
| --- | --- |
| `Get-InstalledProductInventory.ps1` | Reads native MSI contexts and related registration for one product without installing, repairing or modifying it. |
| `Get-InstalledProductInventoryBatch.ps1` | Reads requested product codes and writes inventories from a separate Windows worker. |
| `Invoke-MsiLifecycle.ps1` | Runs the lifecycle script in a bounded child process and retains output, including timeout failures. |

The MSI and WinGet lifecycle tests call these helpers to keep native queries and
installer processes isolated. Inventory requires Windows; the supervisor defaults
to `../Test-WinGetMsiLifecycle.ps1`. Output directories belong in CI artifacts or
temporary storage.
