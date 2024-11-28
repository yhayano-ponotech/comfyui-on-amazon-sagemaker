import json
import os
import base64
import boto3
import logging
from linebot import LineBotApi, WebhookHandler
from linebot.exceptions import InvalidSignatureError
from linebot.models import (
    MessageEvent, TextMessage, TextSendMessage,
    ImageSendMessage
)
import requests

# ロガーの設定
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# 環境変数
CHANNEL_SECRET = os.getenv('LINE_CHANNEL_SECRET')
CHANNEL_ACCESS_TOKEN = os.getenv('LINE_CHANNEL_ACCESS_TOKEN')
COMFYUI_LAMBDA_ARN = os.getenv('COMFYUI_LAMBDA_ARN')

# LINEクライアントの初期化
line_bot_api = LineBotApi(CHANNEL_ACCESS_TOKEN)
handler = WebhookHandler(CHANNEL_SECRET)

# Lambda clientの初期化
lambda_client = boto3.client('lambda')

def upload_to_s3(image_data: bytes, bucket: str) -> str:
    """画像データをS3にアップロードし、URLを取得"""
    s3_client = boto3.client('s3')
    file_name = f"generated/{str(uuid.uuid4())}.jpg"
    
    s3_client.put_object(
        Bucket=bucket,
        Key=file_name,
        Body=image_data,
        ContentType='image/jpeg'
    )
    
    url = s3_client.generate_presigned_url(
        'get_object',
        Params={'Bucket': bucket, 'Key': file_name},
        ExpiresIn=3600
    )
    return url

def lambda_handler(event, context):
    # リクエストヘッダーの取得
    signature = event['headers'].get('x-line-signature', '')
    body = event['body']
    
    try:
        # Webhookの検証
        handler.handle(body, signature)
    except InvalidSignatureError:
        return {
            'statusCode': 400,
            'body': json.dumps({'error': 'Invalid signature'})
        }
    
    # イベントの解析
    events = json.loads(body)['events']
    for event in events:
        if event['type'] == 'message' and event['message']['type'] == 'text':
            user_id = event['source']['userId']
            prompt = event['message']['text']
            
            try:
                # 処理中メッセージを送信
                line_bot_api.push_message(
                    user_id,
                    TextSendMessage(text="画像を生成中です...")
                )
                
                # ComfyUI Lambda関数を呼び出し
                payload = {
                    "body": json.dumps({
                        "positive_prompt": prompt,
                        "negative_prompt": "nsfw, nude, naked,",
                        "prompt_file": "workflow_api.json"
                    })
                }
                
                response = lambda_client.invoke(
                    FunctionName=COMFYUI_LAMBDA_ARN,
                    InvocationType='RequestResponse',
                    Payload=json.dumps(payload)
                )
                
                # レスポンスの処理
                response_payload = json.loads(response['Payload'].read())
                image_data = base64.b64decode(response_payload['body'])
                
                # 画像をS3にアップロード
                image_url = upload_to_s3(image_data, "your-bucket-name")
                
                # 生成された画像を送信
                line_bot_api.push_message(
                    user_id,
                    ImageSendMessage(
                        original_content_url=image_url,
                        preview_image_url=image_url
                    )
                )
                
            except Exception as e:
                logger.error(f"Error: {str(e)}")
                line_bot_api.push_message(
                    user_id,
                    TextSendMessage(text="申し訳ありません。画像の生成中にエラーが発生しました。")
                )
    
    return {
        'statusCode': 200,
        'body': json.dumps({'message': 'OK'})
    }
