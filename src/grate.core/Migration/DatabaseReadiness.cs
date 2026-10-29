using System.Data.Common;
using System.Transactions;

namespace grate.Migration;

internal static class DatabaseReadiness
{
    internal static async Task Wait(IDatabase database)
    {
        const int maxAttempts = 10;

        for (var attempt = 1; ; attempt++)
        {
            try
            {
                // A database can be ONLINE while new connections still fail (including cached login failures).
                using var scope = new TransactionScope(TransactionScopeOption.Suppress, TransactionScopeAsyncFlowOption.Enabled);
                using (await database.OpenNewActiveConnection())
                {
                }
                scope.Complete();
                return;
            }
            catch (DbException) when (attempt < maxAttempts)
            {
                await Task.Delay(1000);
            }
        }
    }
}
