-- Every point the player puts on a sheet leaves the character's pool. Only
-- `spent` is debited: an adjustment in `modifier` is the rules' doing and costs
-- nothing in either direction. The debit lives here rather than in the server
-- so that no write path can raise `spent` without paying for it. Overspending
-- is refused by the pool's own CHECK in 0060, with the same SQLSTATE as any
-- other constraint.
CREATE FUNCTION debit_attribute_points() RETURNS TRIGGER AS $fn$
BEGIN
    UPDATE characters
    SET attribute_points = attribute_points - (NEW.spent - OLD.spent)
    WHERE id = NEW.character;
    RETURN NULL;
END;
$fn$ LANGUAGE plpgsql;

CREATE TRIGGER character_attributes_debit
AFTER UPDATE OF spent ON character_attributes
FOR EACH ROW
WHEN (NEW.spent <> OLD.spent)
EXECUTE FUNCTION debit_attribute_points();
