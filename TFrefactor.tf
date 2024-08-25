# variable "report_location" {
#   type    = string
#   default = "s3://${aws_s3_bucket.reportStorage.bucket}/ash-pipeline/source_out/"
# }
data "aws_caller_identity" "current" {}
variable "date_iso" {
  type    = string
  default = "test-time"
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "reportStorage" {
  tags = {
    Name        = "reportStorage"
    Environment = "Dev"
  }
}
resource "aws_iam_role_policy" "codebuild_cloudwatch_policy" {
  name = "codebuild_cloudwatch_policy"
  role = aws_iam_role.ash_codebuild_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = [
          "arn:aws:logs:*:*:log-group:/aws/codebuild/*",
          "arn:aws:logs:*:*:log-group:/aws/codebuild/*:log-stream:*"
        ]
      }
    ]
  })
}
resource "aws_iam_policy_attachment" "codebuild_cloudwatch_policy_attachment" {
  name       = "codebuild_cloudwatch_policy_attachment"
  roles      = [aws_iam_role.ash_codebuild_role.name]
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}
resource "aws_iam_role" "ash_codebuild_role" {
  name = "ash_codebuild_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_policy_attachment" "codebuild_role_policy_attachment" {
  name       = "codebuild_role_policy_attachment"
  roles      = [aws_iam_role.ash_codebuild_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_codebuild_project" "ash_codebuild_project" {
  name          = "terraform-refactored-ash"
  description   = "security checks for code"
  build_timeout = 60
  service_role  = aws_iam_role.ash_codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/terraform-refactored-ash"
      stream_name = "log-stream"
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/awslabs/automated-security-helper.git"
    git_clone_depth = 1

    git_submodules_config {
      fetch_submodules = true
    }

    buildspec = <<-EOF
    version: 0.2

    phases:
      install:
        commands:
          - echo "Cloning ASH"
          - git clone https://github.com/aws-samples/automated-security-helper.git /tmp/ash
          - echo "Installing yq"
          - curl -Lo /usr/bin/yq https://github.com/mikefarah/yq/releases/download/v4.25.1/yq_linux_amd64
          - chmod +x /usr/bin/yq
          - echo "Downloading sechub_finding.yaml from S3"
          - aws s3 cp s3://${aws_s3_bucket.reportStorage.bucket}/sechub_finding.yaml .
      build:
        commands:
          - echo "Running ASH..."
          - if /tmp/ash/ash --source-dir .; then echo "scan completed"; else echo "found vulnerabilities" && echo "Sending alert to SecHub" && scan_fail=1; fi
      post_build:
        commands:
          - echo "Uploading report to s3://${aws_s3_bucket.reportStorage.bucket}/ash-pipeline/source_out/"
          - sechub_finding=$(yq eval '.' sechub_finding.yaml)
          - echo "$sechub_finding"
          - echo "$sechub_finding" > aggregated_results.txt
          - aws s3 cp aggregated_results.txt s3://${aws_s3_bucket.reportStorage.bucket}/ash-pipeline/source_out/
          - echo "$sechub_finding"
          - if [ "$scan_fail" -eq "1" ]; then aws securityhub batch-import-findings --findings "$sechub_finding"; fi

    artifacts:
      files:
        - '**/*'
EOF

  }

  source_version = "master"

  tags = {
    Environment = "Test"
  }
}

resource "aws_codepipeline" "example" {
  name     = "ash-pipeline"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.reportStorage.bucket
  }

  stage {
    name = "Source"

    action {
      name             = "SourceRepo"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner      = "necroslay"
        Repo       = "tf_test"
        Branch     = "main"
        OAuthToken = var.github_oauth_token
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.ash_codebuild_project.name
      }
    }
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name = "codepipeline_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "codepipeline.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.reportStorage.arn,
          "${aws_s3_bucket.reportStorage.arn}/*"
        ]
      },
      {
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Effect   = "Allow"
        Resource = aws_codebuild_project.ash_codebuild_project.arn
      },
    ]
  })
}

variable "github_oauth_token" {
  type    = string
  default = "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"
}
