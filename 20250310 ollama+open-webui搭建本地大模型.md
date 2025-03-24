## ollama+open-webui搭建本地大模型

### 查看ollama版本
curl http://localhost:11434/api/version

### 第一种方法：
```
launchctl setenv OLLAMA_HOST "0.0.0.0" 
launchctl setenv OLLAMA_KEEP_ALIVE "-1"
``` 
### 第二种方法：
```
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_KEEP_ALIVE=-1 ollama serve

docker run -d -p 3000:8080 -e OLLAMA_BASE_URL=http://192.168.3.61:11434 -v $PWD:/app/backend/data --name open-webui --restart always ghcr.nju.edu.cn/open-webui/open-webui:main
```

