-- These rows skip the server, which is what fills a new character's pool of
-- trained skill points from its age, so they carry it themselves.
INSERT INTO characters (name, level, kin, profession, age, trained_skill_points) VALUES
    ('Alice', 1, 3, 1, 1, (SELECT trained_skill_count FROM ages WHERE id = 1)),
    ('Bob', 2, 2, 2, 1, (SELECT trained_skill_count FROM ages WHERE id = 1));
