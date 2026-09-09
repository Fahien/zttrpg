INSERT INTO kins (name, icon, movement) VALUES
    ($val$Human$val$, (SELECT id FROM icons WHERE name = $val$human-ear$val$ LIMIT 1), $val$10$val$),
    ($val$Orc$val$, (SELECT id FROM icons WHERE name = $val$orc-head$val$ LIMIT 1), $val$10$val$),
    ($val$Undead$val$, (SELECT id FROM icons WHERE name = $val$half-dead$val$ LIMIT 1), $val$10$val$),
    ($val$Gnome$val$, (SELECT id FROM icons WHERE name = $val$bad-gnome$val$ LIMIT 1), $val$8$val$),
    ($val$Dwarf$val$, (SELECT id FROM icons WHERE name = $val$dwarf-face$val$ LIMIT 1), $val$8$val$),
    ($val$Night Elf$val$, (SELECT id FROM icons WHERE name = $val$elf-ear$val$ LIMIT 1), $val$10$val$),
    ($val$Worgen$val$, (SELECT id FROM icons WHERE name = $val$werewolf$val$ LIMIT 1), $val$12$val$),
    ($val$Troll$val$, (SELECT id FROM icons WHERE name = $val$troll$val$ LIMIT 1), $val$10$val$),
    ($val$Tauren$val$, (SELECT id FROM icons WHERE name = $val$minotaur$val$ LIMIT 1), $val$10$val$);
