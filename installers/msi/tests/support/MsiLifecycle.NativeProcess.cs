#nullable enable
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Grate.MsiTests;

// Test-only Windows worker ownership. No redirected readers or PID reacquisition.
public sealed class MsiLifecycleNativeProcess : IDisposable
{
    private readonly SafeProcessHandle process;

    private MsiLifecycleNativeProcess(SafeProcessHandle process, uint id)
    {
        this.process = process;
        Id = unchecked((int)id);
    }

    public int Id { get; }

    public int ExitCode
    {
        get
        {
            if (!WaitForExit(0))
            {
                throw new InvalidOperationException("The MSI worker is still running.");
            }
            if (!GetExitCodeProcess(process, out var code))
            {
                throw NativeFailure("GetExitCodeProcess");
            }
            return unchecked((int)code);
        }
    }

    public static MsiLifecycleNativeProcess Start(string executable, string arguments, string stdoutPath, string stderrPath, string directory)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("MSI worker supervision requires Windows.");
        }
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentException.ThrowIfNullOrWhiteSpace(stdoutPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(stderrPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        if (executable.Contains('"') || executable.Contains('\0') || arguments.Contains('\0'))
        {
            throw new ArgumentException("The executable and command line must be valid Windows arguments.");
        }
        if (string.Equals(Path.GetFullPath(stdoutPath), Path.GetFullPath(stderrPath), StringComparison.OrdinalIgnoreCase))
        {
            throw new ArgumentException("Worker stdout and stderr require separate files.");
        }
        var commandLine = new StringBuilder("\"" + executable + "\" " + arguments);
        if (commandLine.Length >= 32767)
        {
            throw new ArgumentException("The worker command line exceeds the Windows limit.");
        }

        using var stdin = OpenFile("NUL", 0x80000000, 3); // GENERIC_READ, OPEN_EXISTING
        using var stdout = OpenFile(stdoutPath, 0x40000000, 2); // GENERIC_WRITE, CREATE_ALWAYS
        using var stderr = OpenFile(stderrPath, 0x40000000, 2);
        var attributes = IntPtr.Zero;
        var handleList = IntPtr.Zero;
        var initialized = false;
        var information = new ProcessInformation();
        try
        {
            var size = UIntPtr.Zero;
            var sizingSucceeded = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            var sizingError = Marshal.GetLastWin32Error();
            if (sizingSucceeded || sizingError != 122 || size == UIntPtr.Zero)
            {
                throw new Win32Exception(sizingError, "InitializeProcThreadAttributeList sizing failed.");
            }
            attributes = Marshal.AllocHGlobal(checked((int)size.ToUInt64()));
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
            {
                throw NativeFailure("InitializeProcThreadAttributeList");
            }
            initialized = true;
            handleList = Marshal.AllocHGlobal(3 * IntPtr.Size);
            Marshal.WriteIntPtr(handleList, 0, stdin.DangerousGetHandle());
            Marshal.WriteIntPtr(handleList, IntPtr.Size, stdout.DangerousGetHandle());
            Marshal.WriteIntPtr(handleList, 2 * IntPtr.Size, stderr.DangerousGetHandle());
            // HANDLE_LIST requires inheritable real handles and CreateProcess(TRUE).
            // The list/value storage must remain alive until the list is deleted.
            if (!UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x00020002), handleList,
                    new UIntPtr((uint)(3 * IntPtr.Size)), IntPtr.Zero, IntPtr.Zero))
            {
                throw NativeFailure("UpdateProcThreadAttribute HANDLE_LIST");
            }
            var startup = new StartupInfoEx
            {
                Info = new StartupInfo
                {
                    Size = Marshal.SizeOf<StartupInfoEx>(),
                    Flags = 0x00000100, // STARTF_USESTDHANDLES
                    Stdin = stdin.DangerousGetHandle(),
                    Stdout = stdout.DangerousGetHandle(),
                    Stderr = stderr.DangerousGetHandle()
                },
                Attributes = attributes
            };
            if (!CreateProcessW(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                    0x00080000, IntPtr.Zero, directory, ref startup, out information)) // EXTENDED_STARTUPINFO_PRESENT
            {
                throw NativeFailure("CreateProcessW");
            }
            var ownedProcess = new SafeProcessHandle(information.Process, true);
            information.Process = IntPtr.Zero;
            return new MsiLifecycleNativeProcess(ownedProcess, information.ProcessId);
        }
        finally
        {
            if (information.Thread != IntPtr.Zero)
            {
                using var thread = new SafeWaitHandle(information.Thread, true);
            }
            if (information.Process != IntPtr.Zero)
            {
                using var untransferredProcess = new SafeProcessHandle(information.Process, true);
            }
            if (initialized)
            {
                DeleteProcThreadAttributeList(attributes);
            }
            if (attributes != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(attributes);
            }
            if (handleList != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(handleList);
            }
        }
    }

    public bool WaitForExit(int milliseconds)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(milliseconds);
        ObjectDisposedException.ThrowIf(process.IsClosed, this);
        var status = WaitForSingleObject(process, (uint)milliseconds);
        if (status == 0)
        {
            return true;
        }
        if (status == 258)
        {
            return false;
        }
        if (status == uint.MaxValue)
        {
            throw NativeFailure("WaitForSingleObject");
        }
        throw new InvalidOperationException($"Unexpected worker wait result: {status}.");
    }

    public void Kill()
    {
        ObjectDisposedException.ThrowIf(process.IsClosed, this);
        if (!TerminateProcess(process, 1))
        {
            var error = Marshal.GetLastWin32Error();
            // A natural exit can race termination. Confirm it using the owned
            // handle instead of reopening a potentially recycled process ID.
            if (WaitForSingleObject(process, 0) != 0)
            {
                throw new Win32Exception(error, "TerminateProcess failed.");
            }
        }
    }

    public void Dispose()
    {
        process.Dispose();
    }

    private static SafeFileHandle OpenFile(string path, uint access, uint creation)
    {
        var security = new SecurityAttributes
        {
            Size = Marshal.SizeOf<SecurityAttributes>(),
            InheritHandle = true
        };
        var handle = CreateFileW(path, access, 7, ref security, creation, 128, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "CreateFileW for MSI worker standard handle failed.");
        }
        return handle;
    }

    private static Win32Exception NativeFailure(string operation)
    {
        return new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed.");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Size;
        public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved;
        public IntPtr Desktop;
        public IntPtr Title;
        public uint X;
        public uint Y;
        public uint Width;
        public uint Height;
        public uint CharacterWidth;
        public uint CharacterHeight;
        public uint FillAttribute;
        public uint Flags;
        public ushort ShowWindow;
        public ushort ReservedLength;
        public IntPtr ReservedData;
        public IntPtr Stdin;
        public IntPtr Stdout;
        public IntPtr Stderr;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo Info;
        public IntPtr Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        ref SecurityAttributes security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr attributes, uint count, uint flags, ref UIntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(IntPtr attributes, uint flags, UIntPtr attribute,
        IntPtr value, UIntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(string application, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint flags, IntPtr environment, string? directory, ref StartupInfoEx startup, out ProcessInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle process, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(SafeProcessHandle process, uint exitCode);
}
