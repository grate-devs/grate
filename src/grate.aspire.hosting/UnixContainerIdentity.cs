using System.Globalization;
using System.Runtime.InteropServices;

namespace Grate.Aspire.Hosting;

internal static class UnixContainerIdentity
{
    internal static string? Current
    {
        get
        {
            if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS() && !OperatingSystem.IsFreeBSD())
            {
                return null;
            }

            return string.Create(CultureInfo.InvariantCulture, $"{GetEffectiveUserId()}:{GetEffectiveGroupId()}");
        }
    }

    [DllImport("libc", EntryPoint = "geteuid", ExactSpelling = true)]
    private static extern uint GetEffectiveUserId();

    [DllImport("libc", EntryPoint = "getegid", ExactSpelling = true)]
    private static extern uint GetEffectiveGroupId();
}
