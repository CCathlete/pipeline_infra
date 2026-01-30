-- Create the marquez database if it doesn't exist
SELECT 'CREATE DATABASE marquez'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'marquez')\gexec
