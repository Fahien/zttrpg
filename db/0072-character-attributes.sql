-- Two rules on a sheet's values. The total stays within the configured range,
-- whatever moved it. And what the player spent never goes back down: points,
-- once submitted, are spent. The rules' adjustments in `modifier` may go
-- either way and answer only to the range.
--
-- Both limits live in configs, which a CHECK constraint cannot read, so this
-- is a trigger. It runs AFTER the row is written because `value` is generated,
-- and generated columns are not computed yet when BEFORE triggers run. STRICT
-- turns a missing config row into an error that names it. Each refusal
-- carries the SQLSTATE of a CHECK violation, so the server answers it the way
-- it answers any constraint: a 400.
CREATE FUNCTION check_character_attribute() RETURNS TRIGGER AS $fn$
DECLARE
    min_value INTEGER;
    max_value INTEGER;
BEGIN
    SELECT value::INTEGER INTO STRICT min_value FROM configs WHERE name = 'attribute_min';
    SELECT value::INTEGER INTO STRICT max_value FROM configs WHERE name = 'attribute_max';

    IF NEW.value < min_value OR NEW.value > max_value THEN
        RAISE EXCEPTION 'attribute value % is outside the range % to %', NEW.value, min_value, max_value
            USING ERRCODE = 'check_violation';
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.spent < OLD.spent THEN
        RAISE EXCEPTION 'points spent on an attribute cannot decrease from % to %', OLD.spent, NEW.spent
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER character_attributes_check
AFTER INSERT OR UPDATE ON character_attributes
FOR EACH ROW
EXECUTE FUNCTION check_character_attribute();
