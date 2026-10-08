module "default_label" {
  source     = "git::https://github.com/betterworks/terraform-null-label.git?ref=tags/0.13.0"
  enabled    = var.enabled
  namespace  = var.namespace
  stage      = var.stage
  name       = var.name
  delimiter  = var.delimiter
  attributes = var.attributes
  tags       = var.tags
}

data "aws_iam_policy_document" "s3_bucket_readonly_policy" {
  # NB: provider v5 rejects a non-empty source_json.
  source_policy_documents = var.policy == "" ? [] : [var.policy]

  statement {
    sid = "ReadOnlyAccounts"

    actions = [
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket"
    ]

    resources = [
      "arn:aws:s3:::${module.default_label.id}",
      "arn:aws:s3:::${module.default_label.id}/*",
    ]
    principals {
      identifiers = length(var.read_only_access_accounts) == 0 ? ["*"] : formatlist("arn:aws:iam::%s:root", var.read_only_access_accounts)
      type        = "AWS"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "default" {
  count  = var.enabled == "true" ? 1 : 0
  bucket = aws_s3_bucket.default[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.sse_algorithm
      kms_master_key_id = var.kms_master_key_id
    }
  }
}
resource "aws_s3_bucket" "default" {
  count         = var.enabled == "true" ? 1 : 0
  bucket        = module.default_label.id
  acl           = var.acl
  force_destroy = var.force_destroy
  policy        = var.readonly_policy_enabled == "true" ? data.aws_iam_policy_document.s3_bucket_readonly_policy.json : var.policy

  versioning {
    enabled = var.versioning_enabled
  }

  # NB: skipped when lifecycle_rules is set; inline and standalone lifecycle config overwrite each other.
  dynamic "lifecycle_rule" {
    for_each = length(var.lifecycle_rules) == 0 ? [1] : []
    content {
      id      = "object-expiration"
      enabled = var.s3_object_expiration_enabled
      expiration {
        days = var.s3_object_expiration_days
      }
    }
  }

  lifecycle {
    ignore_changes = [
      versioning,
      replication_configuration,
      lifecycle_rule
    ]
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = var.sse_algorithm
        kms_master_key_id = var.kms_master_key_id
      }
    }
  }

  tags = module.default_label.tags
}


module "s3_user" {
  source       = "git::https://github.com/betterworks/terraform-aws-iam-s3-user.git?ref=tags/0.5.1"
  namespace    = var.namespace
  stage        = var.stage
  name         = var.name
  attributes   = var.attributes
  tags         = var.tags
  enabled      = var.enabled == "true" && var.user_enabled == "true" ? "true" : "false"
  s3_actions   = var.allowed_bucket_actions
  s3_resources = ["${join("", aws_s3_bucket.default.*.arn)}/*", join("", aws_s3_bucket.default.*.arn)]
}


data "aws_iam_policy_document" "bucket_policy" {
  count = var.enabled == "true" && var.allow_encrypted_uploads_only == "true" ? 1 : 0

  statement {
    sid       = "DenyIncorrectEncryptionHeader"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.default[0].id}/*"]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "StringNotEquals"
      values   = [var.sse_algorithm]
      variable = "s3:x-amz-server-side-encryption"
    }
  }

  statement {
    sid       = "DenyUnEncryptedObjectUploads"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${aws_s3_bucket.default[0].id}/*"]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "Null"
      values   = ["true"]
      variable = "s3:x-amz-server-side-encryption"
    }
  }
}

resource "aws_s3_bucket_policy" "default" {
  count  = var.enabled == "true" && var.allow_encrypted_uploads_only == "true" ? 1 : 0
  bucket = join("", aws_s3_bucket.default.*.id)

  policy = join("", data.aws_iam_policy_document.bucket_policy.*.json)
}


resource "aws_s3_bucket_lifecycle_configuration" "default" {
  count  = var.enabled == "true" && length(var.lifecycle_rules) > 0 ? 1 : 0
  bucket = aws_s3_bucket.default[0].id

  dynamic "rule" {
    for_each = var.lifecycle_rules
    content {
      id     = rule.value.id
      status = lookup(rule.value, "enabled", true) ? "Enabled" : "Disabled"

      filter {
        prefix = lookup(rule.value, "prefix", null)
      }

      dynamic "transition" {
        for_each = lookup(rule.value, "transitions", [])
        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      dynamic "expiration" {
        for_each = lookup(rule.value, "expiration_days", null) != null || lookup(rule.value, "expired_object_delete_marker", null) != null ? [1] : []
        content {
          days                         = lookup(rule.value, "expiration_days", null)
          expired_object_delete_marker = lookup(rule.value, "expired_object_delete_marker", null)
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = lookup(rule.value, "noncurrent_version_expiration_days", null) != null ? [1] : []
        content {
          noncurrent_days = rule.value.noncurrent_version_expiration_days
        }
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = lookup(rule.value, "abort_incomplete_multipart_upload_days", null) != null ? [1] : []
        content {
          days_after_initiation = rule.value.abort_incomplete_multipart_upload_days
        }
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "default" {
  count                   = var.enabled == "true" && var.block_public_access_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.default[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
