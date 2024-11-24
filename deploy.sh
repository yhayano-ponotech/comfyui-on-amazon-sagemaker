#!/bin/bash

set -e # Exit on error
set -u # Exit on undefined variable
# set -x # Print commands

# Generate a hash for lambda folder content
lambda_hash() {
    # --sort=name   # requires GNU Tar 1.28+
    tar \
     --mtime="@0" \
     --owner=0 --group=0 --numeric-owner \
     --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
     -cf - lambda | md5sum | head -c 6
}

# Set global variables for deployment, to be run after prepare_env functions
configure() {
    # Application name prefix for resourceis provisioned (and also CloudFormation stack name)
    APP_NAME="comfyui"

    # Git reference of ComfyUI (should be a commit id instead of a branch name for production)
    COMFYUI_GIT_REF="v0.0.6"

    # S3 bucket for deployment files (model artifact and Lambda package)
    # Note: Adjust ComfyUIModelExecutionRole in template.yaml to grant S3 related permissions if the bucket name does not contain "SageMaker", "Sagemaker" or "sagemaker".
    S3_BUCKET="comfyui-sagemaker-${AWS_ACCOUNT_ID}-${AWS_DEFAULT_REGION}"

    # Filename of lambda package on S3 bucket used during CloudFormation deployment
    LAMBDA_FILE="lambda-$(lambda_hash).zip"

    # Identifier of SageMaker model and endpoint config
    MODEL_VERSION="sample"

    # Filename of model artifact on S3 bucket
    MODEL_FILE="model-artificact-${MODEL_VERSION}.tgz"

    # ECR repository of SageMaker inference image
    IMAGE_REPO="comfyui-sagemaker"

    # Image tag of SageMaker inference image
    IMAGE_TAG="latest"

    # ECR registry for SageMaker inference image
    IMAGE_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

    # Full image URI for SageMaker inference image
    IMAGE_URI="${IMAGE_REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"

    # Instance type of SageMaker endpoint
    SAGEMAKER_INSTANCE_TYPE="ml.g5.xlarge"

    # Whether to enable auto scaling for the SageMaker endpoint
    SAGEMAKER_AUTO_SCALING="false"

    # Authentication type for the Lambda URL (NONE or AWS_IAM)
    LAMBDA_URL_AUTH_TYPE="AWS_IAM"

    # LINE Bot関連の設定を追加
    LINE_CHANNEL_SECRET=${LINE_CHANNEL_SECRET:-""}
    LINE_CHANNEL_ACCESS_TOKEN=${LINE_CHANNEL_ACCESS_TOKEN:-""}

    # LINE Bot用のLambdaパッケージファイル名
    LINE_BOT_LAMBDA_FILE="line-bot-lambda-$(line_bot_lambda_hash).zip"
}

# Collect variables from AWS environment
prepare_env() {
    ARCH=$(uname -m)
    if [ "${ARCH}" != "x86_64" ]; then
        echo "Error: You must build on x86_64 architecture that matches SageMaker endpoint running"
        exit 1
    fi
    SUPPORT_AMD64=$(docker buildx inspect --bootstrap | grep "^Platforms:" | grep -o -m1 "linux/amd64" | head -n1)
    if [ -z "$SUPPORT_AMD64" ]; then
        echo "Error: docker does not support platform linux/amd64"
        echo "You may try running: docker run --privileged --rm tonistiigi/binfmt --install all"
        exit 1
    fi
    # get AWS region from AWS profile if not previously defined
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-$(aws configure get region || true)}"
    if [ -z "${AWS_DEFAULT_REGION}" ]; then
        # get AWS region from EC2 metadata
        TOKEN=$(curl --max-time 10 -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
        if [ -z "${TOKEN}" ]; then
            echo "Error: AWS_DEFAULT_REGION is empty"
            exit 1
        fi
        AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region -H "X-aws-ec2-metadata-token: $TOKEN" || true)
    fi
    export AWS_DEFAULT_REGION
    echo "AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION}"

    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    echo "AWS_ACCOUNT_ID: ${AWS_ACCOUNT_ID}"
}

# Create ECR repository if not exist
prepare_ecr() {
    ECR_REPO_URI=$(aws ecr describe-repositories --repository-names "${IMAGE_REPO}" --query 'repositories[?repositoryName==`'${IMAGE_REPO}'`].repositoryUri' --output text 2>/dev/null || true)

    if [ -z "$ECR_REPO_URI" ]; then
        echo "Repository $IMAGE_REPO does not exist. Creating it..."
        ECR_REPO_URI=$(aws ecr create-repository \
            --repository-name "$IMAGE_REPO" \
            --encryption-configuration encryptionType=KMS \
            --image-scanning-configuration scanOnPush=true \
            --query 'repository.repositoryUri' \
            --output text)
        echo "Repository created with URI: $ECR_REPO_URI"
    else
        echo "Repository URI: $ECR_REPO_URI"
    fi
}

# Create S3 bucket if not exist
prepare_s3() {
    if aws s3 ls "s3://$S3_BUCKET" >/dev/null 2>&1; then
        echo "Bucket $S3_BUCKET exists"
        return
    fi

    echo "Bucket $S3_BUCKET does not exist. Creating it..."
    # Create the bucket
    aws s3 mb "s3://$S3_BUCKET" --region "$AWS_DEFAULT_REGION"

    # Enable bucket encryption with AWS-managed KMS key
    aws s3api put-bucket-encryption --bucket "$S3_BUCKET" --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms", "KMSMasterKeyID": "alias/aws/s3"}}]}'

    echo "Bucket created: $S3_BUCKET"
}

# Login to ECR
login_ecr() {
    aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" | docker login --username AWS --password-stdin "${IMAGE_REGISTRY}"
}

# Build and push image for inference
build_and_push_image() {
    cd image
    docker build \
        --platform linux/amd64 \
        -t ${IMAGE_URI} \
        -f Dockerfile.inference \
        --build-arg="COMFYUI_GIT_REF=${COMFYUI_GIT_REF}" \
        .
    docker push ${IMAGE_URI}
    cd -
}

# Pack and upload model artifact to S3
build_and_upload_model_artifact() {
    cd model
    ./build.sh "s3://$S3_BUCKET/$MODEL_FILE"
    cd -
}

# Deploy CloudFormation
deploy_cloudformation() {
    # first pack lambda package and upload to S3 bucket
    cd lambda/comfyui
    zip -r $LAMBDA_FILE *
    aws s3 cp "$LAMBDA_FILE" "s3://$S3_BUCKET/lambda/$LAMBDA_FILE"
    cd -

    # CloudFormationスタックのデプロイ
    echo "Deploying CloudFormation stack..."
    aws cloudformation deploy --template-file cloudformation/template.yml \
        --stack-name "$APP_NAME" \
        --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
        --parameter-overrides \
        AppName="$APP_NAME" \
        DeploymentBucket="$S3_BUCKET" \
        LambdaPackageS3Key="lambda/$LAMBDA_FILE" \
        LineBotLambdaS3Key="lambda/$LINE_BOT_LAMBDA_FILE" \
        ModelVersion="$MODEL_VERSION" \
        ModelDataS3Key="$MODEL_FILE" \
        ModelEcrImage="$IMAGE_REPO:$IMAGE_TAG" \
        SageMakerInstanceType="$SAGEMAKER_INSTANCE_TYPE" \
        SageMakerAutoScaling="$SAGEMAKER_AUTO_SCALING" \
        LambdaUrlAuthType="$LAMBDA_URL_AUTH_TYPE" \
        LineChannelSecret="$LINE_CHANNEL_SECRET" \
        LineChannelAccessToken="$LINE_CHANNEL_ACCESS_TOKEN"

    # CloudFormationスタックの出力を表示
    aws cloudformation describe-stacks \
        --stack-name "$APP_NAME" \
        --query 'Stacks[0].Outputs[*].{OutputKey:OutputKey,OutputValue:OutputValue}' \
        --output table
}

# LINE Bot Lambda用のハッシュ関数を追加
line_bot_lambda_hash() {
    tar \
     --mtime="@0" \
     --owner=0 --group=0 --numeric-owner \
     --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
     -cf - lambda/line_bot | md5sum | head -c 6
}

# LINE Bot Lambdaのデプロイ用関数を追加
deploy_line_bot_lambda() {
    # LINE Botの認証情報チェック
    if [ -z "${LINE_CHANNEL_SECRET}" ] || [ -z "${LINE_CHANNEL_ACCESS_TOKEN}" ]; then
        echo "Error: LINE_CHANNEL_SECRET and LINE_CHANNEL_ACCESS_TOKEN must be set"
        exit 1
    fi

    # LINE Bot Lambda用のパッケージを作成
    cd lambda/line_bot
    pip install -r requirements.txt -t .
    zip -r $LINE_BOT_LAMBDA_FILE *
    aws s3 cp "$LINE_BOT_LAMBDA_FILE" "s3://$S3_BUCKET/lambda/$LINE_BOT_LAMBDA_FILE"
    cd -
}

# メイン処理フロー
prepare_env
configure
prepare_ecr
prepare_s3
login_ecr
build_and_push_image
build_and_upload_model_artifact
deploy_line_bot_lambda  # 追加
deploy_cloudformation
echo "Done"
