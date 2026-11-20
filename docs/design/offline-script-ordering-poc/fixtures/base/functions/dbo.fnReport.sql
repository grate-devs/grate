CREATE OR ALTER FUNCTION dbo.fnReport()
RETURNS TABLE
AS
RETURN (SELECT orders.Total AS ReportTotal FROM dbo.vOrders AS orders);
