INSERT INTO kins_skills (kin, skill) VALUES
    ((SELECT id FROM kins WHERE name = $val$Human$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Adaptive$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Orc$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Berserker$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Undead$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Tough$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Gnome$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Hard To Catch$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Dwarf$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Unforgiving$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Night Elf$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Camouflage$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Worgen$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Hunting Instinct$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Troll$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Nine Lives$val$ LIMIT 1)),
    ((SELECT id FROM kins WHERE name = $val$Tauren$val$ LIMIT 1), (SELECT id FROM skills WHERE name = $val$Body Slam$val$ LIMIT 1));
