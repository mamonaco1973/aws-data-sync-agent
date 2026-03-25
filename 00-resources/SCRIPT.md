# Video Script — AWS DataSync: EFS to S3 Data Migration

---

## Introduction

[Show DataSync task executions running with throughput and file counts updating]

Moving large datasets between storage systems can be complicated. You need reliable transfers, integrity checks, and the ability to run migrations at scale.

[Show Task Details]

AWS DataSync is a managed service designed for this problem. 

[Show AWS source and target locations]

It moves data between storage systems efficiently while handling scheduling, retries, verification, and incremental transfers so large migrations can stay synchronized until the final cutover.

[Show the full migration flow diagram briefly with no highlights]

In this project we'll build a complete DataSync migration pipeline using Terraform and watch it move data between storage systems.

---

## Architecture

[ FULL DIAGRAM ON SCREEN ]

Now let's review the architecture.

[ Highlight LEFT column: "EFS Source Locations" ]

On the left side are the source file systems. Each of these directories lives inside an Amazon EFS file system.

These represent different datasets that we want to migrate.

[ Highlight CENTER column: "DataSync Tasks" ]

In the middle are the AWS DataSync tasks.

Each task is responsible for scanning a source location
and synchronizing its contents to a destination.

[ Highlight RIGHT column: "S3 Destination Locations" ]

On the right side are the S3 destinations.

Each task writes the synchronized data into a corresponding prefix inside an S3 bucket.

[ Highlight ONE FULL ROW across the diagram ]

The flow is simple.

DataSync reads files from EFS, transfers them across the service, and writes them into S3.

[ Highlight BOTTOM: Task Execution Lifecycle ]

When a task runs, it moves through several phases.

It starts queued, launches the transfer workers,prepares the dataset, performs the transfer, verifies the results, and finally completes successfully.

## Build Results

[ Show AWS Console – DataSync → Locations ]

After the build completes, the DataSync locations are created.

Here we have the EFS source location and the S3 destination location that will receive the migrated data.

[ Switch to DataSync → Tasks ]

Terraform also created the DataSync tasks.

Each task maps a specific EFS directory to a corresponding destination prefix in S3.

[ Click one task: sync-aws-efs ]

If we open one of the tasks, you can see the source EFS location and the destination S3 bucket configuration.

[ Switch to S3 Console – open destination bucket ]

This is the destination S3 bucket.

Each DataSync task writes to its own prefix inside the bucket.

## Demo

[ Show Validate.sh]

Now let's run the migration. The validate script triggers the DataSync tasks.

[ Show Build happening]

Here we can see the task execution moving through the transfer lifecycle.

[Show the transfer statistics]

Since the initial sync already completed,  DataSync only checks for changes.

In this case there are no updates so nothing needs to be transferred.

[Show S3 bucket]

The data is already present in S3, so the task simply verifies that the source and destination are in sync.

This incremental behavior makes DataSync useful for large migrations where a final sync is needed just before cutover.
