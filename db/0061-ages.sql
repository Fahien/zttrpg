INSERT INTO ages (name, icon, trained_skill_count) VALUES
    ($val$Young$val$, (SELECT id FROM icons WHERE name = $val$baby-face$val$ LIMIT 1), 8),
    ($val$Adult$val$, (SELECT id FROM icons WHERE name = $val$person$val$ LIMIT 1), 10),
    ($val$Old$val$, (SELECT id FROM icons WHERE name = $val$wizard-face$val$ LIMIT 1), 12);
