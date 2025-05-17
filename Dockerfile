FROM ruby:3.2

# 安装必要组件
RUN apt-get update -qq && apt-get install -y build-essential libpq-dev nodejs

# 安装 bundler
RUN gem install bundler

# 设置工作目录
WORKDIR /srv/jekyll

# 复制项目代码
COPY . .

# 安装依赖
RUN bundle install
