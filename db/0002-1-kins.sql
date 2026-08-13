INSERT INTO kins (name, icon) VALUES
    ('Human', (SELECT id FROM icons WHERE name = 'human-ear' LIMIT 1)),
    ('Orc', (SELECT id FROM icons WHERE name = 'orc-head' LIMIT 1)),
    ('Undead', (SELECT id FROM icons WHERE name = 'half-dead' LIMIT 1));
