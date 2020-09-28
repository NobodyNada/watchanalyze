# watchanalyze

Gather statistics on SmokeDetector watchlist items

---

This is a simple (and slightly hacky) script that checks the SmokeDetector watchlist against a metasmoke data dump. Each watchlist item is tested against every post that has been reported since the watch was first added, and the number of total posts caught, the number of true positives, and the number of FPs/NAAs are saved to a CSV file.

Note that this script uses Foundation's regex implementation (based on ICU regex), so it may produce slightly different results than Smokey.

## Usage

    I ~> mysql -u root -p
    Enter password: 
    Welcome to the MySQL monitor.  Commands end with ; or \g.
    Your MySQL connection id is 367
    Server version: 8.0.19 Homebrew

    Copyright (c) 2000, 2020, Oracle and/or its affiliates. All rights reserved.

    Oracle is a registered trademark of Oracle Corporation and/or its
    affiliates. Other names may be trademarks of their respective
    owners.

    Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

    mysql> CREATE DATABASE dump_metasmoke;
    Query OK, 1 row affected (0.00 sec)

    mysql> CREATE USER metasmoke;
    Query OK, 0 rows affected (0.00 sec)

    mysql> GRANT ALL PRIVILEGES ON dump_metasmoke.* TO metasmoke;
    Query OK, 0 rows affected (0.00 sec)

    mysql> exit
    Bye
    I ~> curl https://dumps.charcoal-se.org/dump_metasmoke_clean-1601251201.sql.gz | gunzip | grep -v '^/\*!\d* DEFINER=' | mysql -u metasmoke -D dump_metasmoke
      % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                     Dload  Upload   Total   Spent    Left  Speed
    100  146M  100  146M    0     0   441k      0  0:05:39  0:05:39 --:--:-- 1365k
    I ~> git clone https://github.com/NobodyNada/watchanalyze
    Cloning into 'watchanalyze'...
    remote: Enumerating objects: 28, done.
    remote: Counting objects: 100% (28/28), done.
    remote: Compressing objects: 100% (12/12), done.
    remote: Total 28 (delta 6), reused 28 (delta 6), pack-reused 0
    Unpacking objects: 100% (28/28), 7.85 KiB | 502.00 KiB/s, done.
    I ~> cd watchanalyze
    I ~/watchanalyze (master)> cp /path/to/SmokeDetector/watched_keywords.txt .
    I ~/watchanalyze (master)> swift run -c release
    ...
