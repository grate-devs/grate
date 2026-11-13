using System.Runtime.InteropServices;
using System.Text.Json;

namespace Grate.Poc.LibPgQuery;

public static class PgQuery
{
    public static JsonDocument Parse(string sql)
    {
        ArgumentNullException.ThrowIfNull(sql);
        if (sql.Contains('\0', StringComparison.Ordinal))
            throw new ArgumentException("SQL must not contain NUL characters.", nameof(sql));

        var result = NativeParse(sql);
        try
        {
            if (result.Error != IntPtr.Zero)
            {
                var error = Marshal.PtrToStructure<NativeError>(result.Error);
                var message = Marshal.PtrToStringUTF8(error.Message)
                    ?? throw new InvalidDataException("Native error did not contain a message.");
                throw new PgQueryParseException(message, error.CursorPosition, error.SourceLine);
            }

            var json = Marshal.PtrToStringUTF8(result.ParseTree)
                ?? throw new InvalidDataException("Native parser returned no parse tree.");
            return JsonDocument.Parse(json);
        }
        finally
        {
            NativeFree(result);
        }
    }

    [DllImport("pg_query", EntryPoint = "pg_query_parse", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    private static extern NativeResult NativeParse([MarshalAs(UnmanagedType.LPUTF8Str)] string sql);

    [DllImport("pg_query", EntryPoint = "pg_query_free_parse_result", CallingConvention = CallingConvention.Cdecl, ExactSpelling = true)]
    private static extern void NativeFree(NativeResult result);

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativeResult
    {
        public readonly IntPtr ParseTree;
        public readonly IntPtr StandardError;
        public readonly IntPtr Error;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly struct NativeError
    {
        public readonly IntPtr Message;
        public readonly IntPtr FunctionName;
        public readonly IntPtr FileName;
        public readonly int SourceLine;
        public readonly int CursorPosition;
        public readonly IntPtr Context;
    }
}

public sealed class PgQueryParseException(string message, int cursorPosition, int nativeSourceLine) : FormatException(message)
{
    public int CursorPosition { get; } = cursorPosition;
    public int NativeSourceLine { get; } = nativeSourceLine;
}
