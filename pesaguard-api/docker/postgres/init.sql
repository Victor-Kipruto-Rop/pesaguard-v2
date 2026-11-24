-- Local development only. Replace passwords; never reuse in staging or production.
CREATE ROLE api_user LOGIN PASSWORD 'change-me';
CREATE ROLE worker_user LOGIN PASSWORD 'change-me';
GRANT ALL PRIVILEGES ON DATABASE pesaguard TO api_user, worker_user;
CREATE DATABASE pesaguard_test;
