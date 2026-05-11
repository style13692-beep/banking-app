var Service = require('node-windows').Service;

var svc = new Service({
  name: 'LumeBankServer',
  description: 'LumeBank Node.js Banking Backend - BN304 Project',
  script: 'C:\\Users\\User\\Documents\\BN304 Project\\Scripts\\server.js',
  nodeOptions: []
});

svc.on('install', function(){
  svc.start();
  console.log('Service installed and started successfully!');
});

svc.install();