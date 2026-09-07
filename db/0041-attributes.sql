INSERT INTO attributes (name, icon, short, description) VALUES
    ($val$Strength$val$, (SELECT id FROM icons WHERE name = $val$fist$val$ LIMIT 1), $val$STR$val$, $val$Raw muscle power.$val$),
    ($val$Constitution$val$, (SELECT id FROM icons WHERE name = $val$muscle-up$val$ LIMIT 1), $val$CON$val$, $val$Physical fitness and resilience.$val$),
    ($val$Agility$val$, (SELECT id FROM icons WHERE name = $val$wingfoot$val$ LIMIT 1), $val$AGL$val$, $val$Body control, speed, and fine motor skills.$val$),
    ($val$Intelligence$val$, (SELECT id FROM icons WHERE name = $val$brain$val$ LIMIT 1), $val$INT$val$, $val$Mental acuity, intellect, and reasoning skills.$val$),
    ($val$Willpower$val$, (SELECT id FROM icons WHERE name = $val$suspicious$val$ LIMIT 1), $val$WIL$val$, $val$Self-discipline and focus.$val$),
    ($val$Charisma$val$, (SELECT id FROM icons WHERE name = $val$polar-star$val$ LIMIT 1), $val$CHA$val$, $val$Force of personality and empathy.$val$);
