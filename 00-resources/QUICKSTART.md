#AWS #DataSync #EFS #S3 #Terraform #CloudMigration #DataTransfer

*AWS DataSync EFS to S3 – Quick Start*

GitHub

https://github.com/mamonaco1973/aws-data-sync

README

https://github.com/mamonaco1973/aws-data-sync/blob/main/README.md

This Quick Start shows you how to migrate data from Amazon EFS to S3 using AWS DataSync and Terraform — with four concurrent transfer tasks running in parallel.

No manual setup.
No console clicking.
Fully automated.
Fully reproducible.

What This Quick Start Deploys

• Three-phase Terraform deployment — Active Directory, EFS + clients, then DataSync
• Samba 4 mini AD domain controller on Ubuntu for lab authentication
• Amazon EFS file system mounted by a domain-joined Linux client
• Four GitHub repositories cloned into EFS as sample migration data
• Four concurrent DataSync tasks — one per repository, each with its own EFS source location and S3 destination prefix
• SSM Parameter Store sentinel that gates DataSync execution until EFS population is complete
• S3 bucket with encryption, versioning, and public access blocked
• IAM role trusted by datasync.amazonaws.com with scoped S3 permissions
