-- corpus/seed/relational.sql — the branch-covering relational seed (tranche 1).
--
-- This is the ADR-0002 dataset and the ADR-0003 source-of-truth, made concrete.
-- It is a SELF-CONTAINED, purpose-built database (ADR-0007) — NOT a slice of the
-- 121 MB WideWorldImporters restore. It creates:
--   * the schemas the selected procedures reference,
--   * minimal tables carrying ONLY the columns those procedures read, at WWI's
--     real types (so the decimal(18,2)/(18,3) precision behaviour is preserved),
--   * branch-covering rows: the minimal set that makes every WHERE / CASE / JOIN
--     arm / window boundary of the 11 tranche-1 procedures produce a DISTINCT,
--     observable result (see the per-table branch notes below).
--
-- The 11 procedures themselves are loaded VERBATIM from corpus/procs/*.sql by the
-- capture step (corpus/capture-golden.sh) — not duplicated here — so there is one
-- source of truth for the proc text. Golden is captured by running those originals
-- against this seed; because the seed is the WHOLE input, golden is a pure function
-- of it by construction (ADR-0003).
--
-- TRANCHE 1 (this file) covers the 11 tractable procedures:
--   Website.SearchForCustomers / SearchForSuppliers / SearchForStockItems /
--   SearchForStockItemsByTags / SearchForPeople
--   Integration.GetOrderUpdates / GetSaleUpdates / GetPurchaseUpdates /
--   GetMovementUpdates / GetTransactionUpdates / GetStockHoldingUpdates
-- The 3 temporal procedures (GetCustomer/Supplier/CityUpdates) need system-
-- versioning + *_Archive history + geography and are TRANCHE 2 (ADR-0007).
--
-- Sizing note (ADR-0002): the working target of "~50–200 rows per key table" is a
-- loose upper band, not a floor. What the ADR actually decrees is "the minimal set
-- that exercises each branch." A handful of rows per table does that here and keeps
-- golden readable; ADR-0006's mutation check is what PROVES the sizing is
-- sufficient — an uncaught mutant is a branch hole and earns another row, not the
-- other way round.
--
-- Determinism: every timestamp is a fixed literal. No GETDATE()/NEWID() anywhere,
-- so re-running this script yields byte-identical data and re-capturing golden is
-- stable (gate: gates/verify-stable.sh).
--
-- Idempotent: drops and recreates the database, so `sqlcmd -i relational.sql`
-- always lands the same state.
--
--   docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd \
--     -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -No -b -i /corpus/seed/relational.sql

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_ID('WwiSeed') IS NOT NULL
BEGIN
    ALTER DATABASE WwiSeed SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE WwiSeed;
END;
GO
CREATE DATABASE WwiSeed;
GO
USE WwiSeed;
GO

-- Schemas the procedures reference (two-part names in the proc bodies).
CREATE SCHEMA Sales;
GO
CREATE SCHEMA Purchasing;
GO
CREATE SCHEMA Warehouse;
GO
CREATE SCHEMA [Application];
GO
CREATE SCHEMA Website;
GO
CREATE SCHEMA Integration;
GO

-- =====================================================================
-- Lookup / dimension tables
-- =====================================================================

-- Cities: only ID + name are read (SearchForCustomers/Suppliers).
CREATE TABLE [Application].Cities
(
    CityID   int          NOT NULL PRIMARY KEY,
    CityName nvarchar(50) NOT NULL
);

-- People: SearchForCustomers/Suppliers read FullName/PreferredName; SearchForPeople
-- additionally reads SearchName + the IsSalesperson/IsEmployee flags that drive its
-- CASE ladder.
CREATE TABLE [Application].People
(
    PersonID      int           NOT NULL PRIMARY KEY,
    FullName      nvarchar(50)  NOT NULL,
    PreferredName nvarchar(50)  NOT NULL,
    SearchName    nvarchar(101) NOT NULL,
    IsSalesperson bit           NOT NULL,
    IsEmployee    bit           NOT NULL
);

-- PackageTypes: ID + name (GetOrder/Sale/PurchaseUpdates).
CREATE TABLE Warehouse.PackageTypes
(
    PackageTypeID   int          NOT NULL PRIMARY KEY,
    PackageTypeName nvarchar(50) NOT NULL
);

-- StockItems: SearchForStockItems (SearchDetails), ...ByTags (Tags, nullable),
-- GetSaleUpdates (IsChillerStock), GetPurchaseUpdates (QuantityPerOuter).
CREATE TABLE Warehouse.StockItems
(
    StockItemID     int            NOT NULL PRIMARY KEY,
    StockItemName   nvarchar(100)  NOT NULL,
    SearchDetails   nvarchar(max)  NOT NULL,
    Tags            nvarchar(max)  NULL,
    IsChillerStock  bit            NOT NULL,
    QuantityPerOuter int           NOT NULL
);

-- =====================================================================
-- Customers / Suppliers
-- =====================================================================

CREATE TABLE Sales.Customers
(
    CustomerID             int          NOT NULL PRIMARY KEY,
    CustomerName           nvarchar(100) NOT NULL,
    DeliveryCityID         int          NOT NULL,
    PhoneNumber            nvarchar(20) NOT NULL,
    FaxNumber              nvarchar(20) NOT NULL,
    PrimaryContactPersonID int          NULL,   -- nullable: exercises the LEFT JOIN / CONCAT-ignores-NULL branch
    BillToCustomerID       int          NOT NULL -- GetSaleUpdates INNER JOINs on this
);

CREATE TABLE Purchasing.Suppliers
(
    SupplierID               int          NOT NULL PRIMARY KEY,
    SupplierName             nvarchar(100) NOT NULL,
    DeliveryCityID           int          NOT NULL,
    PhoneNumber              nvarchar(20) NOT NULL,
    FaxNumber                nvarchar(20) NOT NULL,
    PrimaryContactPersonID   int          NULL,
    AlternateContactPersonID int          NULL
);

-- =====================================================================
-- Orders / OrderLines
-- =====================================================================

CREATE TABLE Sales.Orders
(
    OrderID             int          NOT NULL PRIMARY KEY,
    CustomerID          int          NOT NULL,
    SalespersonPersonID int          NOT NULL,
    PickedByPersonID    int          NULL,
    BackorderOrderID    int          NULL,   -- null vs set: exercises the [WWI Backorder ID] projection
    OrderDate           date         NOT NULL,
    LastEditedWhen      datetime2(7) NOT NULL
);

CREATE TABLE Sales.OrderLines
(
    OrderLineID          int           NOT NULL PRIMARY KEY,
    OrderID              int           NOT NULL,
    StockItemID          int           NOT NULL,
    [Description]        nvarchar(100) NOT NULL,
    PackageTypeID        int           NOT NULL,
    Quantity             int           NOT NULL,
    UnitPrice            decimal(18,2) NULL,
    TaxRate              decimal(18,3) NOT NULL,
    PickingCompletedWhen datetime2(7)  NULL,   -- null → CAST(NULL AS date) [Picked Date Key] branch
    LastEditedWhen       datetime2(7)  NOT NULL
);

-- =====================================================================
-- Invoices / InvoiceLines
-- =====================================================================

CREATE TABLE Sales.Invoices
(
    InvoiceID             int          NOT NULL PRIMARY KEY,
    CustomerID            int          NOT NULL,
    BillToCustomerID      int          NOT NULL,
    InvoiceDate           date         NOT NULL,
    ConfirmedDeliveryTime datetime2(7) NULL,   -- null → CAST(NULL AS date) [Delivery Date Key] branch
    SalespersonPersonID   int          NOT NULL,
    LastEditedWhen        datetime2(7) NOT NULL
);

CREATE TABLE Sales.InvoiceLines
(
    InvoiceLineID  int           NOT NULL PRIMARY KEY,
    InvoiceID      int           NOT NULL,
    StockItemID    int           NOT NULL,
    [Description]  nvarchar(100) NOT NULL,
    PackageTypeID  int           NOT NULL,
    Quantity       int           NOT NULL,
    UnitPrice      decimal(18,2) NULL,
    TaxRate        decimal(18,3) NOT NULL,
    TaxAmount      decimal(18,2) NOT NULL,
    LineProfit     decimal(18,2) NOT NULL,
    ExtendedPrice  decimal(18,2) NOT NULL,
    LastEditedWhen datetime2(7)  NOT NULL
);

-- =====================================================================
-- Purchase orders / lines
-- =====================================================================

CREATE TABLE Purchasing.PurchaseOrders
(
    PurchaseOrderID int          NOT NULL PRIMARY KEY,
    SupplierID      int          NOT NULL,
    OrderDate       date         NOT NULL,
    LastEditedWhen  datetime2(7) NOT NULL
);

CREATE TABLE Purchasing.PurchaseOrderLines
(
    PurchaseOrderLineID  int          NOT NULL PRIMARY KEY,
    PurchaseOrderID      int          NOT NULL,
    StockItemID          int          NOT NULL,
    OrderedOuters        int          NOT NULL,
    ReceivedOuters       int          NOT NULL,
    PackageTypeID        int          NOT NULL,
    IsOrderLineFinalized bit          NOT NULL,
    LastEditedWhen       datetime2(7) NOT NULL
);

-- =====================================================================
-- Transactions
-- =====================================================================

CREATE TABLE Warehouse.StockItemTransactions
(
    StockItemTransactionID int          NOT NULL PRIMARY KEY,
    TransactionOccurredWhen datetime2(7) NOT NULL,
    InvoiceID              int          NULL,   -- issue vs receipt: null/set combos observable
    PurchaseOrderID        int          NULL,
    Quantity               decimal(18,3) NOT NULL,
    StockItemID            int          NOT NULL,
    CustomerID             int          NULL,
    SupplierID             int          NULL,
    TransactionTypeID      int          NOT NULL,
    LastEditedWhen         datetime2(7) NOT NULL
);

CREATE TABLE Sales.CustomerTransactions
(
    CustomerTransactionID int          NOT NULL PRIMARY KEY,
    CustomerID            int          NOT NULL,
    TransactionTypeID     int          NOT NULL,
    InvoiceID             int          NULL,   -- null → COALESCE(i.CustomerID, ct.CustomerID) fallback branch
    PaymentMethodID       int          NULL,
    TransactionDate       date         NOT NULL,
    AmountExcludingTax    decimal(18,2) NOT NULL,
    TaxAmount             decimal(18,2) NOT NULL,
    TransactionAmount     decimal(18,2) NOT NULL,
    OutstandingBalance    decimal(18,2) NOT NULL,
    IsFinalized           bit          NULL,
    LastEditedWhen        datetime2(7) NOT NULL
);

CREATE TABLE Purchasing.SupplierTransactions
(
    SupplierTransactionID int          NOT NULL PRIMARY KEY,
    SupplierID            int          NOT NULL,
    TransactionTypeID     int          NOT NULL,
    PurchaseOrderID       int          NULL,
    PaymentMethodID       int          NULL,
    SupplierInvoiceNumber nvarchar(20) NULL,
    TransactionDate       date         NOT NULL,
    AmountExcludingTax    decimal(18,2) NOT NULL,
    TaxAmount             decimal(18,2) NOT NULL,
    TransactionAmount     decimal(18,2) NOT NULL,
    OutstandingBalance    decimal(18,2) NOT NULL,
    IsFinalized           bit          NULL,
    LastEditedWhen        datetime2(7) NOT NULL
);

CREATE TABLE Warehouse.StockItemHoldings
(
    StockItemID           int          NOT NULL PRIMARY KEY,
    QuantityOnHand        int          NOT NULL,
    BinLocation           nvarchar(20) NOT NULL,
    LastStocktakeQuantity int          NOT NULL,
    LastCostPrice         decimal(18,2) NOT NULL,
    ReorderLevel          int          NOT NULL,
    TargetStockLevel      int          NOT NULL
);
GO

-- =====================================================================
-- DATA
-- =====================================================================

-- Cities ---------------------------------------------------------------
INSERT [Application].Cities (CityID, CityName) VALUES
    (1, N'Seattle'),
    (2, N'Portland'),
    (3, N'Boston');

-- People ---------------------------------------------------------------
-- Branch intent for SearchForPeople's CASE ladder + COALESCE company:
--   1 salesperson (first arm)   -> 'Salesperson', company COALESCE -> 'WWI'
--   2 employee   (second arm)   -> 'Employee',    company 'WWI'
--   3 customer primary contact  -> 'Customer',    company = customer name
--   4 supplier primary contact  -> 'Supplier',    company = supplier name
--   5 supplier alternate contact-> 'Supplier',    company = supplier name (sa arm)
--   6 no relationship at all     -> NULL,          company 'WWI' (final COALESCE fallback)
INSERT [Application].People (PersonID, FullName, PreferredName, SearchName, IsSalesperson, IsEmployee) VALUES
    (1, N'Amy Salesperson',  N'Amy',      N'Amy Salesperson',  1, 1),
    (2, N'Ben Employee',     N'Ben',      N'Ben Employee',     0, 1),
    (3, N'Cara Customer',    N'Cara',     N'Cara Customer',    0, 0),
    (4, N'Dan Supplier',     N'Dan',      N'Dan Supplier',     0, 0),
    (5, N'Eve Alternate',    N'Eve',      N'Eve Alternate',    0, 0),
    (6, N'Fay Unlinked',     N'Fay',      N'Fay Unlinked',     0, 0);

-- PackageTypes ---------------------------------------------------------
INSERT Warehouse.PackageTypes (PackageTypeID, PackageTypeName) VALUES
    (1, N'Each'),
    (2, N'Carton');

-- StockItems -----------------------------------------------------------
-- SearchDetails/Tags drive the two SearchFor* match paths; item 4 has NULL Tags
-- (so ...ByTags can never return it — the LIKE-on-NULL branch); item 3 is chiller.
INSERT Warehouse.StockItems (StockItemID, StockItemName, SearchDetails, Tags, IsChillerStock, QuantityPerOuter) VALUES
    (1, N'USB rocket launcher',  N'USB rocket launcher gadget',  N'["Gadget"]',           0, 10),
    (2, N'USB missile launcher', N'USB missile launcher gadget', N'["Gadget"]',           0, 12),
    (3, N'Chocolate frogs 250g', N'Chocolate frogs 250g',        N'["Chocolate"]',        1,  6),
    (4, N'Plain cardboard box',  N'Plain cardboard box',         NULL,                    0, 25),
    (5, N'USB food warmer',      N'USB food warmer novelty',     N'["Gadget","Novelty"]', 0,  8);

-- Customers ------------------------------------------------------------
-- Customer 1 has a primary contact (person 3 -> the 'Customer' arm of SearchForPeople);
-- customer 2 has NULL contact (SearchForCustomers still matches it on name because
-- CONCAT ignores NULL — the null-contact branch).
INSERT Sales.Customers (CustomerID, CustomerName, DeliveryCityID, PhoneNumber, FaxNumber, PrimaryContactPersonID, BillToCustomerID) VALUES
    (1, N'Tailspin Toys (Head)', 1, N'555-0100', N'555-0101', 3,    1),
    (2, N'Wingtip Toys',         2, N'555-0200', N'555-0201', NULL, 1);

-- Suppliers ------------------------------------------------------------
-- Supplier 1: primary contact person 4, alternate person 5 (feeds SearchForPeople
-- 'Supplier' arms sp and sa). Supplier 2: null contacts (null-contact branch).
INSERT Purchasing.Suppliers (SupplierID, SupplierName, DeliveryCityID, PhoneNumber, FaxNumber, PrimaryContactPersonID, AlternateContactPersonID) VALUES
    (1, N'Litware Supplies', 3, N'555-0300', N'555-0301', 4,    5),
    (2, N'Contoso Parts',    1, N'555-0400', N'555-0401', NULL, NULL);

-- Orders / OrderLines --------------------------------------------------
-- [Last Modified When] = MAX(orderline.LastEditedWhen, order.LastEditedWhen).
--   Order 1: order edited 2020-01-10, line edited 2020-01-20 -> line wins (2020-01-20)
--   Order 2: order edited 2020-02-20, line edited 2020-02-10 -> order wins (2020-02-20)
-- so the two arms of that CASE are both observed, and a Jan-only vs Feb-only vs
-- both-months window (param-cases) selects distinct row sets.
INSERT Sales.Orders (OrderID, CustomerID, SalespersonPersonID, PickedByPersonID, BackorderOrderID, OrderDate, LastEditedWhen) VALUES
    (1, 1, 1, 1,    NULL, '2020-01-05', '2020-01-10 09:00:00'),
    (2, 2, 1, NULL, 1,    '2020-02-05', '2020-02-20 09:00:00');

INSERT Sales.OrderLines (OrderLineID, OrderID, StockItemID, [Description], PackageTypeID, Quantity, UnitPrice, TaxRate, PickingCompletedWhen, LastEditedWhen) VALUES
    (1, 1, 1, N'USB rocket launcher',  1, 10,  25.00, 15.000, '2020-01-06 12:00:00', '2020-01-20 09:00:00'),
    (2, 2, 2, N'USB missile launcher', 2,  3, 100.00, 10.000, NULL,                  '2020-02-10 09:00:00');
-- ROUND arithmetic (GetOrderUpdates):
--   Line1: Excl=ROUND(10*25.00,2)=250.00; Tax=ROUND(250.00*15/100,2)=37.50; Incl=287.50
--   Line2: Excl=ROUND(3*100.00,2)=300.00; Tax=ROUND(300.00*10/100,2)=30.00; Incl=330.00

-- Invoices / InvoiceLines ----------------------------------------------
-- Invoice 1: dry item (StockItem 1, IsChiller=0) -> [Total Dry Items]=Qty, Chiller=0;
--            ConfirmedDeliveryTime set.
-- Invoice 2: chiller item (StockItem 3) -> [Total Chiller Items]=Qty, Dry=0;
--            ConfirmedDeliveryTime NULL -> CAST(NULL AS date) delivery-key branch.
INSERT Sales.Invoices (InvoiceID, CustomerID, BillToCustomerID, InvoiceDate, ConfirmedDeliveryTime, SalespersonPersonID, LastEditedWhen) VALUES
    (1, 1, 1, '2020-01-05', '2020-01-07 15:00:00', 1, '2020-01-20 09:00:00'),
    (2, 2, 1, '2020-02-05', NULL,                  1, '2020-02-20 09:00:00');

INSERT Sales.InvoiceLines (InvoiceLineID, InvoiceID, StockItemID, [Description], PackageTypeID, Quantity, UnitPrice, TaxRate, TaxAmount, LineProfit, ExtendedPrice, LastEditedWhen) VALUES
    (1, 1, 1, N'USB rocket launcher',  1, 10, 25.00, 15.000, 37.50, 50.00, 287.50, '2020-01-20 09:00:00'),
    (2, 2, 3, N'Chocolate frogs 250g', 2,  6,  5.00, 10.000,  3.00, 12.00,  33.00, '2020-02-20 09:00:00');
-- GetSaleUpdates: [Total Excluding Tax]=ExtendedPrice-TaxAmount (250.00 / 30.00);
--                 [Total Including Tax]=ExtendedPrice (287.50 / 33.00).

-- Purchase orders / lines ----------------------------------------------
-- [Ordered Quantity] = OrderedOuters * StockItem.QuantityPerOuter.
--   PO line1: 5 * 10 = 50 ; IsOrderLineFinalized = 1
--   PO line2: 3 * 12 = 36 ; IsOrderLineFinalized = 0  (both bit arms observed)
INSERT Purchasing.PurchaseOrders (PurchaseOrderID, SupplierID, OrderDate, LastEditedWhen) VALUES
    (1, 1, '2020-01-05', '2020-01-20 09:00:00'),
    (2, 2, '2020-02-05', '2020-02-20 09:00:00');

INSERT Purchasing.PurchaseOrderLines (PurchaseOrderLineID, PurchaseOrderID, StockItemID, OrderedOuters, ReceivedOuters, PackageTypeID, IsOrderLineFinalized, LastEditedWhen) VALUES
    (1, 1, 1, 5, 5, 2, 1, '2020-01-20 09:00:00'),
    (2, 2, 2, 3, 0, 1, 0, '2020-02-20 09:00:00');

-- StockItemTransactions ------------------------------------------------
-- SIT 1: an ISSUE to a customer (InvoiceID + CustomerID set, PO + Supplier NULL),
--        Quantity negative. SIT 2: a RECEIPT from a supplier (PO + Supplier set,
--        Invoice + Customer NULL), Quantity positive. Exercises the null/set
--        projection columns and the Jan/Feb window.
INSERT Warehouse.StockItemTransactions (StockItemTransactionID, TransactionOccurredWhen, InvoiceID, PurchaseOrderID, Quantity, StockItemID, CustomerID, SupplierID, TransactionTypeID, LastEditedWhen) VALUES
    (1, '2020-01-10 12:00:00', 1,    NULL, -10.000, 1, 1,    NULL, 10, '2020-01-20 09:00:00'),
    (2, '2020-02-10 12:00:00', NULL, 1,     50.000, 1, NULL, 1,    11, '2020-02-20 09:00:00');

-- CustomerTransactions -------------------------------------------------
-- CT 1: has an InvoiceID -> LEFT JOIN Invoices hits -> COALESCE(i.CustomerID,...) = i side.
-- CT 2: InvoiceID NULL    -> LEFT JOIN misses       -> COALESCE falls back to ct.CustomerID.
INSERT Sales.CustomerTransactions (CustomerTransactionID, CustomerID, TransactionTypeID, InvoiceID, PaymentMethodID, TransactionDate, AmountExcludingTax, TaxAmount, TransactionAmount, OutstandingBalance, IsFinalized, LastEditedWhen) VALUES
    (1, 1, 1, 1,    NULL, '2020-01-05', 250.00, 37.50, 287.50,   0.00, 1, '2020-01-20 09:00:00'),
    (2, 2, 1, NULL, 4,    '2020-02-05', 100.00, 10.00, 110.00, 110.00, 0, '2020-02-20 09:00:00');

-- SupplierTransactions -------------------------------------------------
-- Feeds the UNION ALL supplier arm of GetTransactionUpdates. One row, in the Jan
-- window, so a Jan window returns CT1 + ST1 (both arms), a Feb window returns CT2 only.
INSERT Purchasing.SupplierTransactions (SupplierTransactionID, SupplierID, TransactionTypeID, PurchaseOrderID, PaymentMethodID, SupplierInvoiceNumber, TransactionDate, AmountExcludingTax, TaxAmount, TransactionAmount, OutstandingBalance, IsFinalized, LastEditedWhen) VALUES
    (1, 1, 5, 1, NULL, N'SI-001', '2020-01-08', 500.00, 50.00, 550.00, 0.00, 1, '2020-01-20 09:00:00');

-- StockItemHoldings ----------------------------------------------------
-- Zero-param GetStockHoldingUpdates returns the whole table ordered by StockItemID.
INSERT Warehouse.StockItemHoldings (StockItemID, QuantityOnHand, BinLocation, LastStocktakeQuantity, LastCostPrice, ReorderLevel, TargetStockLevel) VALUES
    (1, 100, N'L-1', 95, 12.50, 20, 200),
    (2,  50, N'L-2', 50,  8.00, 10, 100);
GO

-- Sanity: row counts, so a re-run's log shows the seed is fully populated.
SELECT 'Cities' AS [table], COUNT(*) AS rows FROM [Application].Cities
UNION ALL SELECT 'People', COUNT(*) FROM [Application].People
UNION ALL SELECT 'PackageTypes', COUNT(*) FROM Warehouse.PackageTypes
UNION ALL SELECT 'StockItems', COUNT(*) FROM Warehouse.StockItems
UNION ALL SELECT 'Customers', COUNT(*) FROM Sales.Customers
UNION ALL SELECT 'Suppliers', COUNT(*) FROM Purchasing.Suppliers
UNION ALL SELECT 'Orders', COUNT(*) FROM Sales.Orders
UNION ALL SELECT 'OrderLines', COUNT(*) FROM Sales.OrderLines
UNION ALL SELECT 'Invoices', COUNT(*) FROM Sales.Invoices
UNION ALL SELECT 'InvoiceLines', COUNT(*) FROM Sales.InvoiceLines
UNION ALL SELECT 'PurchaseOrders', COUNT(*) FROM Purchasing.PurchaseOrders
UNION ALL SELECT 'PurchaseOrderLines', COUNT(*) FROM Purchasing.PurchaseOrderLines
UNION ALL SELECT 'StockItemTransactions', COUNT(*) FROM Warehouse.StockItemTransactions
UNION ALL SELECT 'CustomerTransactions', COUNT(*) FROM Sales.CustomerTransactions
UNION ALL SELECT 'SupplierTransactions', COUNT(*) FROM Purchasing.SupplierTransactions
UNION ALL SELECT 'StockItemHoldings', COUNT(*) FROM Warehouse.StockItemHoldings;
GO
