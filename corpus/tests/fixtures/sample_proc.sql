CREATE PROCEDURE Sales.SampleSearch
    @SearchText NVARCHAR(100),
    @MaxRows INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SELECT TOP(@MaxRows)
        o.OrderID,
        o.Total,
        CAST(o.OrderID AS INT) AS OrderIdInt,
        CAST(o.Total AS DECIMAL(18,2)) AS TotalCast,
        c.CustomerName
    FROM Sales.Orders AS o
    INNER JOIN Sales.Customers AS c ON c.CustomerID = o.CustomerID
    LEFT JOIN Sales.People AS p ON p.PersonID = o.SalespersonID
    WHERE CONCAT(o.OrderID, N' ', c.CustomerName) LIKE N'%' + @SearchText + N'%'
    ORDER BY c.CustomerName
    FOR JSON AUTO, ROOT('Orders');

    RETURN 0;
END;
