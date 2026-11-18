# 1) Start an agent in this shell
eval "$(ssh-agent -s)"

# 2) Load your key (you'll be prompted once)
ssh-add ~/.ssh/id_rsa
