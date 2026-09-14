SET NOCOUNT ON;

IF EXISTS (
    SELECT email FROM sales.customer GROUP BY email HAVING COUNT(*)>1
) THROW 51001,'TEST FAILED: duplicate customer email.',1;

IF EXISTS (
    SELECT 1 FROM inventory.product WHERE stock_quantity<0 OR unit_price<=0
) THROW 51002,'TEST FAILED: invalid product balance or price.',1;

IF EXISTS (
    SELECT 1
    FROM sales.sales_order o
    CROSS APPLY(
        SELECT SUM(i.line_total)-o.discount_amount due
        FROM sales.order_item i WHERE i.order_id=o.order_id
    ) d
    CROSS APPLY(
        SELECT COALESCE(SUM(p.amount),0) paid
        FROM sales.payment p WHERE p.order_id=o.order_id
    ) p
    WHERE p.paid>d.due
) THROW 51003,'TEST FAILED: order is overpaid.',1;

IF EXISTS (
    SELECT order_id
    FROM sales.order_item
    GROUP BY order_id,product_id
    HAVING COUNT(*)>1
) THROW 51004,'TEST FAILED: duplicated product in order.',1;

IF EXISTS (
    SELECT 1
    FROM sales.sales_order o
    WHERE o.status IN('PAID','SHIPPED')
      AND NOT EXISTS(SELECT 1 FROM sales.payment p WHERE p.order_id=o.order_id)
) THROW 51005,'TEST FAILED: finalized order without payment.',1;

DECLARE @before int=(SELECT stock_quantity FROM inventory.product WHERE product_id=1);
DECLARE @id bigint;
DECLARE @lines sales.order_line_type;
INSERT @lines VALUES(1,1);

BEGIN TRANSACTION;
EXEC sales.usp_create_order @customer_id=1,@lines=@lines,@order_id=@id OUTPUT;

IF (SELECT stock_quantity FROM inventory.product WHERE product_id=1)<>@before-1
BEGIN
    ROLLBACK;
    THROW 51006,'TEST FAILED: procedure did not reserve stock.',1;
END
ROLLBACK;

PRINT 'ALL DATA QUALITY TESTS PASSED';
GO
