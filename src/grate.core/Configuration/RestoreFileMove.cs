namespace grate.Configuration;

/// <summary>A backup file's logical name and its destination on the SQL Server host.</summary>
public sealed record RestoreFileMove(string LogicalName, string DestinationPath);
