# grate

grate is a SQL scripts migration runner, using plain, old SQL for migrations. No meta-language, no code, no config,
no EF migrations. It gives you full flexibility, and full control of your migrations, and lets you use
all the fancy features of you particular database system. You are not constrained to any lowest common
feature set of all supported databases.

## Minimal example
The only required argument to pass to grate is a **connection string** to tell it where to find your database. 
It will deploy to that database, looking for sql scripts in the current directory.

```
grate --connectionstring="Server=(localdb)\MSSQLLocalDB;Integrated Security=true;Database=grate_test"
```

for more configuration options, see the [documentation](https://grate-devs.github.io/grate/configuration-options/).



## grate supports the following DMBS's

* Microsoft SQL server
* PostgreSQL
* MariaDB/MySQL
* Sqlite
* Oracle

Full documentation can be found at [https://grate-devs.github.io/grate/](https://grate-devs.github.io/grate/).


