require 'spec_helper'

include Wechat::Cipher

ENCODING_AES_KEY = Base64.encode64 SecureRandom.hex(16)

class WechatCorpController < ApplicationController
  wechat_responder corpid: 'corpid', corpsecret: 'corpsecret', token: 'token', access_token: 'controller_access_token',
                   agentid: 1, encoding_aes_key: ENCODING_AES_KEY
end

RSpec.describe WechatCorpController, type: :controller do
  render_views

  let(:message_base) do
    {
      ToUserName: 'toUser',
      FromUserName: 'fromUser',
      CreateTime: '1348831860',
      MsgId: '1234567890123456'
    }
  end

  def signature_params(msg = {})
    xml = message_base.merge(msg).to_xml(root: :xml, skip_instruct: true)

    encrypt = Base64.strict_encode64 encrypt(pack(xml, 'appid'), ENCODING_AES_KEY)
    xml = { Encrypt: encrypt }
    timestamp = '1234567'
    nonce = 'nonce'
    msg_signature = Digest::SHA1.hexdigest(['token', timestamp, nonce, xml[:Encrypt]].sort.join)
    { timestamp: timestamp, nonce: nonce, xml: xml, msg_signature: msg_signature }
  end

  def signature_echostr(echostr)
    encrypt_echostr = Base64.strict_encode64 encrypt(pack(echostr, 'appid'), ENCODING_AES_KEY)
    timestamp = '1234567'
    nonce = 'nonce'
    msg_signature = Digest::SHA1.hexdigest(['token', timestamp, nonce, encrypt_echostr].sort.join)
    { timestamp: timestamp, nonce: nonce, echostr: encrypt_echostr, msg_signature: msg_signature }
  end

  def xml_to_hash(xml_message)
    Hash.from_xml(xml_message)['xml'].symbolize_keys
  end

  describe 'Verify signature' do
    it 'on create action faild' do
      post :create, signature_params.merge(msg_signature: 'invalid')
      expect(response.code).to eq '403'
    end

    it 'on create action success' do
      post :create, signature_params(MsgType: 'voice', Voice: { MediaId: 'mediaID' })
      expect(response.code).to eq '200'
      expect(response.body.length).to eq 0
    end
  end

  specify "echo 'echostr' param when show" do
    get :show, signature_echostr('hello')
    expect(response.body).to eq('hello')
  end

  describe 'corp' do
    controller do
      wechat_responder corpid: 'corpid', corpsecret: 'corpsecret', token: 'token', access_token: 'controller_access_token',
                       agentid: 1, encoding_aes_key: ENCODING_AES_KEY

      on :text do |request, content|
        request.reply.text "echo: #{content}"
      end

      on :text, with: 'mpnews' do |request|
        request.reply.news(0...1) do |article|
          article.item title: 'title', description: 'desc', pic_url: 'http://www.baidu.com/img/bdlogo.gif', url: 'http://www.baidu.com/'
        end
      end

      on :event, with: 'subscribe' do |request|
        request.reply.text 'welcome!'
      end

      on :event, with: 'enter_agent' do |request|
        request.reply.text 'echo: enter_agent'
      end

      on :click, with: 'BOOK_LUNCH' do |request, key|
        request.reply.text "#{request[:FromUserName]} click #{key}"
      end

      on :scan, with: 'BINDING_QR_CODE' do |request, scan_result, scan_type|
        request.reply.text "User #{request[:FromUserName]} ScanResult #{scan_result} ScanType #{scan_type}"
      end

      on :scan, with: 'BINDING_BARCODE' do |message, scan_result|
        if scan_result.start_with? 'CODE_39,'
          message.reply.text "User: #{message[:FromUserName]} scan barcode, result is #{scan_result.split(',')[1]}"
        end
      end

      on :batch_job, with: 'replace_user' do |request, batch_job|
        request.reply.text "Replace user job #{batch_job[:JobId]} finished, return code #{batch_job[:ErrCode]}, return message #{batch_job[:ErrMsg]}"
      end
    end

    specify 'will set controller wechat api and token' do
      access_token = controller.class.wechat.access_token
      expect(access_token.token_file).to eq 'controller_access_token'
      expect(controller.class.token).to eq 'token'
      expect(controller.class.agentid).to eq 1
      expect(controller.class.encrypt_mode).to eq true
      expect(controller.class.encoding_aes_key).to eq ENCODING_AES_KEY
    end

    describe 'response' do
      it 'Verify response signature' do
        post :create, signature_params(MsgType: 'text', Content: 'hello')
        expect(response.code).to eq '200'
        expect(response.body.empty?).to eq false

        data = Hash.from_xml(response.body)['xml']

        msg_signature = Digest::SHA1.hexdigest [data['TimeStamp'], data['Nonce'], 'token', data['Encrypt']].sort.join
        expect(data['MsgSignature']).to eq msg_signature
      end

      it 'on text' do
        post :create, signature_params(MsgType: 'text', Content: 'hello')
        expect(response.code).to eq '200'
        expect(response.body.empty?).to eq false

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'echo: hello'
      end

      it 'on mpnews' do
        post :create, signature_params(MsgType: 'text', Content: 'mpnews')
        expect(response.code).to eq '200'
        expect(response.body.empty?).to eq false

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))

        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        articles = { 'item' => { 'Title' => 'title',
                                 'Description' => 'desc',
                                 'PicUrl' => 'http://www.baidu.com/img/bdlogo.gif',
                                 'Url' => 'http://www.baidu.com/' } }
        expect(message['MsgType']).to eq 'news'
        expect(message['ArticleCount']).to eq '1'
        expect(message['Articles']).to eq articles
      end

      it 'on subscribe' do
        post :create, signature_params(MsgType: 'event', Event: 'subscribe')
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'welcome!'
      end

      it 'on enter_agent' do
        post :create, signature_params(MsgType: 'event', Event: 'click', EventKey: 'enter_agent')
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'echo: enter_agent'
      end

      it 'on click BOOK_LUNCH' do
        post :create, signature_params(MsgType: 'event', Event: 'click', EventKey: 'BOOK_LUNCH')
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'fromUser click BOOK_LUNCH'
      end

      it 'on BINDING_QR_CODE' do
        post :create, signature_params(FromUserName: 'userid', MsgType: 'event', Event: 'scancode_push', EventKey: 'BINDING_QR_CODE',
                                       ScanCodeInfo: { ScanType: 'qrcode', ScanResult: 'scan_result' })
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'User userid ScanResult scan_result ScanType qrcode'
      end

      it 'response scancode event with matched event' do
        post :create, signature_params(FromUserName: 'userid', MsgType: 'event', Event: 'scancode_waitmsg', EventKey: 'BINDING_BARCODE',
                                       ScanCodeInfo: { ScanType: 'qrcode', ScanResult: 'CODE_39,SAP0D00' })
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'User: userid scan barcode, result is SAP0D00'
      end

      it 'on replace_user' do
        post :create, signature_params(FromUserName: 'sys', MsgType: 'event', Event: 'batch_job_result',
                                       BatchJob: { JobId: 'job_id', JobType: 'replace_user', ErrCode: 0, ErrMsg: 'ok' })
        expect(response.code).to eq '200'

        data = Hash.from_xml(response.body)['xml']

        xml_message, app_id = unpack(decrypt(Base64.decode64(data['Encrypt']), ENCODING_AES_KEY))
        expect(app_id).to eq 'appid'
        expect(xml_message.empty?).to eq false

        message = Hash.from_xml(xml_message)['xml']
        expect(message['MsgType']).to eq 'text'
        expect(message['Content']).to eq 'Replace user job job_id finished, return code 0, return message ok'
      end
    end
  end
end
