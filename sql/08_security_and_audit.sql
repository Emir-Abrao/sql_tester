CREATE OR ALTER FUNCTION platform.fn_tenant_security(@tenant_id int)
RETURNS TABLE WITH SCHEMABINDING
AS RETURN SELECT 1 access_granted
WHERE @tenant_id=TRY_CONVERT(int,SESSION_CONTEXT(N'tenant_id'))
   OR IS_MEMBER('db_owner')=1;
GO

CREATE SECURITY POLICY platform.tenant_security_policy
ADD FILTER PREDICATE platform.fn_tenant_security(tenant_id) ON sales.customer,
ADD BLOCK PREDICATE platform.fn_tenant_security(tenant_id) ON sales.customer AFTER INSERT,
ADD FILTER PREDICATE platform.fn_tenant_security(tenant_id) ON sales.sales_order,
ADD BLOCK PREDICATE platform.fn_tenant_security(tenant_id) ON sales.sales_order AFTER INSERT,
ADD FILTER PREDICATE platform.fn_tenant_security(tenant_id) ON inventory.product,
ADD BLOCK PREDICATE platform.fn_tenant_security(tenant_id) ON inventory.product AFTER INSERT
WITH(STATE=ON);
GO

CREATE OR ALTER PROCEDURE platform.usp_set_tenant_context @tenant_id int
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS(SELECT 1 FROM platform.tenant WHERE tenant_id=@tenant_id AND is_active=1)
        THROW 54001,'Tenant not found or inactive.',1;
    EXEC sys.sp_set_session_context @key=N'tenant_id',@value=@tenant_id,@read_only=1;
END;
GO

CREATE OR ALTER TRIGGER sales.trg_sales_order_audit
ON sales.sales_order
AFTER INSERT,UPDATE,DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT audit.change_event
      (tenant_id,entity_name,entity_id,action_type,changed_by,before_json,after_json)
    SELECT COALESCE(i.tenant_id,d.tenant_id),'sales.sales_order',
           CONVERT(varchar(100),COALESCE(i.order_id,d.order_id)),
           CASE WHEN i.order_id IS NULL THEN 'DELETE'
                WHEN d.order_id IS NULL THEN 'INSERT' ELSE 'UPDATE' END,
           COALESCE(TRY_CONVERT(nvarchar(128),SESSION_CONTEXT(N'actor')),ORIGINAL_LOGIN()),
           CASE WHEN d.order_id IS NULL THEN NULL ELSE
             (SELECT d.order_id,d.customer_id,d.status,d.discount_amount,d.order_date
              FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) END,
           CASE WHEN i.order_id IS NULL THEN NULL ELSE
             (SELECT i.order_id,i.customer_id,i.status,i.discount_amount,i.order_date
              FOR JSON PATH,WITHOUT_ARRAY_WRAPPER) END
    FROM inserted i FULL OUTER JOIN deleted d ON d.order_id=i.order_id;
END;
GO

CREATE ROLE commerce_reader;
CREATE ROLE commerce_operator;
CREATE ROLE commerce_analyst;

GRANT SELECT ON SCHEMA::analytics TO commerce_analyst;
GRANT SELECT ON SCHEMA::sales TO commerce_reader;
GRANT SELECT ON SCHEMA::inventory TO commerce_reader;
GRANT EXECUTE ON OBJECT::sales.usp_create_order_v2 TO commerce_operator;
GRANT EXECUTE ON OBJECT::sales.usp_cancel_order TO commerce_operator;
GRANT EXECUTE ON OBJECT::sales.usp_register_payment TO commerce_operator;
GRANT EXECUTE ON OBJECT::platform.usp_set_tenant_context TO commerce_reader;
GRANT EXECUTE ON OBJECT::platform.usp_set_tenant_context TO commerce_operator;
GRANT EXECUTE ON OBJECT::platform.usp_set_tenant_context TO commerce_analyst;
DENY SELECT ON SCHEMA::audit TO commerce_reader,commerce_operator,commerce_analyst;
GO
