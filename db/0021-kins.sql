INSERT INTO kins (name, icon) VALUES
    ($val$Human$val$, (SELECT id FROM icons WHERE name = $val$human-ear$val$ LIMIT 1)),
    ($val$Orc$val$, (SELECT id FROM icons WHERE name = $val$orc-head$val$ LIMIT 1)),
    ($val$Undead$val$, (SELECT id FROM icons WHERE name = $val$half-dead$val$ LIMIT 1));
