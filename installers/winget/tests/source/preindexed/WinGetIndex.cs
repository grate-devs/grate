// Test harness interop for the official Microsoft.WindowsPackageManager.Utils
// 1.29.380 native ABI. The DLL performs all schema/index/normalization work.
using System;
using System.Reflection;
using System.Runtime.InteropServices;

public static class GrateWinGetIndex
{
    public static void Load(string library)
    {
        NativeLibrary.SetDllImportResolver(typeof(GrateWinGetIndex).Assembly,
            (name, assembly, path) => name == "GratePinnedWinGetUtil" ? NativeLibrary.Load(library) : IntPtr.Zero);
    }

    [DllImport("GratePinnedWinGetUtil", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void WinGetLoggingInit(string path);
    [DllImport("GratePinnedWinGetUtil", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void WinGetLoggingTerm(string path);
    [DllImport("GratePinnedWinGetUtil", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void WinGetSQLiteIndexCreate(string path, uint major, uint minor, out IntPtr index);
    [DllImport("GratePinnedWinGetUtil", CharSet = CharSet.Unicode, PreserveSig = false)]
    public static extern void WinGetSQLiteIndexAddManifest(IntPtr index, string path, string relativePath);
    [DllImport("GratePinnedWinGetUtil", PreserveSig = false)]
    public static extern void WinGetSQLiteIndexPrepareForPackaging(IntPtr index);
    [DllImport("GratePinnedWinGetUtil", PreserveSig = false)]
    public static extern void WinGetSQLiteIndexCheckConsistency(IntPtr index, [MarshalAs(UnmanagedType.Bool)] out bool consistent);
    [DllImport("GratePinnedWinGetUtil", PreserveSig = false)]
    public static extern void WinGetSQLiteIndexClose(IntPtr index);
}
