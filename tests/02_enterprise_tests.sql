SET NOCOUNT ON;
EXEC platform.usp_set_tenant_context @tenant_id=1;

IF EXISTS(
 SELECT 1 FROM sales.sales_order o
 JOIN sales.customer c ON c.customer_id=o.customer_id
 WHERE o.tenant_id<>c.tenant_id
) THROW 55001,'TEST FAILED: cross-tenant order/customer relation.',1;

IF EXISTS(
 SELECT tenant_id,idempotency_key FROM integration.idempotency_key
 GROUP BY tenant_id,idempotency_key HAVING COUNT(*)>1
) THROW 55002,'TEST FAILED: duplicated idempotency key.',1;

IF EXISTS(
 SELECT 1 FROM integration.outbox_event
 WHERE ISJSON(payload)=0 OR retry_count<0
) THROW 55003,'TEST FAILED: invalid outbox event.',1;

DECLARE @before int=(SELECT stock_quantity FROM inventory.product WHERE product_id=1);
DECLARE @order_id bigint,@same_order_id bigint;
DECLARE @key uniqueidentifier=NEWID(),@hash binary(32)=HASHBYTES('SHA2_256','test-request');
DECLARE @lines sales.order_line_type;
INSERT @lines VALUES(1,1);

BEGIN TRANSACTION;
EXEC sales.usp_create_order_v2 1,1,@lines,0,@key,@hash,@order_id OUTPUT;
EXEC sales.usp_create_order_v2 1,1,@lines,0,@key,@hash,@same_order_id OUTPUT;

IF @order_id<>@same_order_id
BEGIN ROLLBACK; THROW 55004,'TEST FAILED: idempotency returned different resources.',1; END;

IF (SELECT stock_quantity FROM inventory.product WHERE product_id=1)<>@before-1
BEGIN ROLLBACK; THROW 55005,'TEST FAILED: idempotent retry changed stock twice.',1; END;

EXEC sales.usp_cancel_order 1,@order_id,N'Automated rollback test',NULL;

IF (SELECT stock_quantity FROM inventory.product WHERE product_id=1)<>@before
BEGIN ROLLBACK; THROW 55006,'TEST FAILED: cancellation did not restore stock.',1; END;

IF NOT EXISTS(SELECT 1 FROM integration.outbox_event
              WHERE aggregate_id=CONVERT(varchar(100),@order_id)
              GROUP BY aggregate_id HAVING COUNT(*)=2)
BEGIN ROLLBACK; THROW 55007,'TEST FAILED: lifecycle events missing.',1; END;

ROLLBACK;
PRINT 'ALL ENTERPRISE TESTS PASSED';
GO
