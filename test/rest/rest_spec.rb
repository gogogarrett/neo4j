$LOAD_PATH << File.expand_path(File.dirname(__FILE__) + "/../../lib")
$LOAD_PATH << File.expand_path(File.dirname(__FILE__) + "/..")

require 'neo4j'
require 'neo4j/extensions/rest'

require 'spec'
require 'spec/interop/test'
require 'rack/test'


# TODO refactor, duplicated code in spec_helper
#require 'neo4j/spec_helper'

require 'fileutils'
require 'tmpdir'

# suppress all warnings
#$NEO_LOGGER.level = Logger::ERROR


def undefine_class2(*clazz_syms)
  clazz_syms.each do |clazz_sym|
    Object.instance_eval do
      begin
        #Neo4j::Indexer.remove_instance const_get(clazz_sym)
        remove_const clazz_sym
      end if const_defined? clazz_sym
    end
  end
end

                  

Sinatra::Application.set :environment, :test

describe 'Restful' do
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  before(:all) do
    NEO_STORAGE = Dir::tmpdir + "/neo_storage"
    LUCENE_INDEX_LOCATION = Dir::tmpdir + "/lucene"
    Lucene::Config[:storage_path] = LUCENE_INDEX_LOCATION
    Lucene::Config[:store_on_file] = true
    Neo4j::Config[:storage_path] = NEO_STORAGE
    FileUtils.rm_rf Neo4j::Config[:storage_path]  # NEO_STORAGE
    FileUtils.rm_rf Lucene::Config[:storage_path] unless Lucene::Config[:storage_path].nil?
    Neo4j.event_handler.remove_all
  end


  before(:each) do
    undefine_class2 :RestPerson
    class RestPerson
      include Neo4j::NodeMixin
      # by including the following mixin we will expose this node as a RESTful resource
      include RestMixin
      property :name
      index :name
      has_n :friends
    end

    undefine_class2 :SomethingElse
    class SomethingElse
      include Neo4j::NodeMixin
      include RestMixin
      property :name
      index :name, :tokenized => true
    end

    Neo4j.start
    Neo4j::Transaction.new
  end

  after(:each) do
    Neo4j::Transaction.finish

    Neo4j.stop
    FileUtils.rm_rf Neo4j::Config[:storage_path]  # NEO_STORAGE
    FileUtils.rm_rf Lucene::Config[:storage_path] unless Lucene::Config[:storage_path].nil?
  end

  it "should support POST ruby code on /neo" do
    code = <<END_OF_STRING
class Foo
include Neo4j::NodeMixin
include RestMixin
property :name
end
END_OF_STRING

    # when
    post "/neo", code
    
    # then
    last_response.status.should == 200
    (defined? Foo).should == "constant"
  end


  it "should know the URI of a RestPerson instance" do
    p = RestPerson.new
    port = Sinatra::Application.port # we do not know it since we have not started it - mocked
    p._uri.should == "http://0.0.0.0:#{port}/nodes/RestPerson/#{p.neo_node_id}"
  end

  it "should be possible to traverse a relationship on GET nodes/RestPerson/<id>/traverse?relation=friends&depth=1" do
    adam = RestPerson.new
    adam.name = 'adam'

    bertil = RestPerson.new
    bertil.name = 'bertil'

    carl = RestPerson.new

    adam.friends << bertil << carl

    # when
    get "/nodes/RestPerson/#{adam.neo_node_id}/traverse?relation=friends&depth=1"

    # then
    last_response.status.should == 200
    body = JSON.parse(last_response.body)
    body['uri_list'].should_not be_nil
    body['uri_list'][0].should == 'http://0.0.0.0:4567/nodes/RestPerson/2'
    body['uri_list'][1].should == 'http://0.0.0.0:4567/nodes/RestPerson/3'
    body['uri_list'].size.should == 2
  end
  
  it "should create a relationship on POST /nodes/RestPerson/friends" do
    adam = RestPerson.new
    adam.name = 'adam'

    bertil = RestPerson.new
    bertil.name = 'bertil'
    bertil.friends << RestPerson.new

    # when
    post "/nodes/RestPerson/#{adam.neo_node_id}/friends", { :uri => bertil._uri }.to_json

    # then
    last_response.status.should == 201
    last_response.location.should == "/relations/1" # starts counting from 0
    adam.friends.should include(bertil)
  end

  it "should list related nodes on GET /nodes/RestPerson/friends" do
    adam = RestPerson.new
    adam.name = 'adam'
    bertil = RestPerson.new
    bertil.name = 'bertil'
    adam.friends << bertil

    # when
    get "/nodes/RestPerson/#{adam.neo_node_id}/friends"

    # then
    last_response.status.should == 200
    body = JSON.parse(last_response.body)
    body.size.should == 1
    body[0]['id'].should == bertil.neo_node_id
  end

  it "should be possible to load a relationship on GET /relations/<id>" do
    adam = RestPerson.new
    bertil = RestPerson.new
    rel = adam.friends.new(bertil)
    rel.set_property("foo", "bar")
    # when
    get "/relations/#{rel.neo_relationship_id}"

    # then
    last_response.status.should == 200
    body = JSON.parse(last_response.body)
    body['foo'].should == 'bar'
  end


  it "should create a new RestPerson on POST /nodes/RestPerson" do
    data = { :name => 'kalle'}

    # when
    post '/nodes/RestPerson', data.to_json

    # then
    last_response.status.should == 201
    last_response.location.should == "/nodes/RestPerson/1"
  end

  it "should persist a new RestPerson created by POST /nodes/RestPerson" do
    data = { :name => 'kalle'}

    # when
    Neo4j::Transaction.finish # run the post outside of a transaction
    Neo4j::Transaction.running?.should == false
    post '/nodes/RestPerson', data.to_json
    location = last_response["Location"]
    get location

    # then
    last_response.status.should == 200
    body = JSON.parse(last_response.body)
    body['name'].should == 'kalle'
  end

  it "should be possible to follow the location HTTP header when creating a new RestPerson" do
    data = { :name => 'kalle'}

    # when
    post '/nodes/RestPerson', data.to_json
    location = last_response["Location"]
    get location

    # then
    last_response.status.should == 200
    body = JSON.parse(last_response.body)
    body['name'].should == 'kalle'
  end

  it "should find a RestPerson on GET /nodes/RestPerson/<neo_node_id>" do
    # given
    p = RestPerson.new
    p.name = 'sune'

    # when
    get "/nodes/RestPerson/#{p.neo_node_id}"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.should include("name")
    data['name'].should == 'sune'
  end

  it "should return a 404 if it can't find the node" do
    get "/nodes/RestPerson/742421"

    # then
    last_response.status.should == 404
  end

  it "should be possible to set all properties on PUT nodes/RestPerson/<node_id>" do
    # given
    p = RestPerson.new
    p.name = 'sune123'
    p[:some_property] = 'foo'

    # when
    data = {:name => 'blah', :dynamic_property => 'cool stuff'}
    put "/nodes/RestPerson/#{p.neo_node_id}", data.to_json

    # then
    last_response.status.should == 200
    p.name.should == 'blah'
    p[:some_property].should be_nil
    p[:dynamic_property].should == 'cool stuff'
  end

  it "should be possible to delete a node on DELETE nodes/RestPerson/<node_id>" do
    # given
    p = RestPerson.new
    p.name = 'asdf'
    id = p.neo_node_id

    # when
    delete "/nodes/RestPerson/#{id}"
    Neo4j::Transaction.current.success # delete only takes effect when transaction has ended
    Neo4j::Transaction.finish
    Neo4j::Transaction.new

    # then
    last_response.status.should == 200
    Neo4j.load(id).should be_nil
  end

  it "should be possible to get a property on GET nodes/RestPerson/<node_id>/<property_name>" do
    # given
    p = RestPerson.new
    p.name = 'sune123'

    # when
    get "/nodes/RestPerson/#{p.neo_node_id}/name"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data['name'].should == 'sune123'
  end

  it "should be possible to set a property on PUT nodes/RestPerson/<node_id>/<property_name>" do
    # given
    p = RestPerson.new
    p.name = 'sune123'

    # when
    data = { :name => 'new-name'}
    put "/nodes/RestPerson/#{p.neo_node_id}/name", data.to_json

    # then
    last_response.status.should == 200
    p.name.should == 'new-name'
  end

  it "should return all nodes of that class type on GET /nodes/RestPerson" do
    # given
    p1 = RestPerson.new
    p1.name = 'p1'
    p2 = RestPerson.new
    p2.name = 'p2'
    e = SomethingElse.new
    e.name = 'p3'
    Neo4j::Transaction.current.success # ensure index gets updated
    Neo4j::Transaction.finish

    # when
    get "/nodes/RestPerson"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.size.should == 2
    data.map{|p| p['name']}.should include("p1")
    data.map{|p| p['name']}.should include("p2")
  end

  it "should search for exact property matches on GET /nodes/RestPerson?name=p" do
    # given
    p1 = RestPerson.new
    p1.name = 'p'
    p1_id = p1.neo_node_id
    p2 = RestPerson.new
    p2.name = 'p2'
    Neo4j::Transaction.current.success # ensure index gets updated
    Neo4j::Transaction.finish

    # when
    get "/nodes/RestPerson?name=p"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.size.should == 1
    data[0]['id'].should == p1_id
    data[0]['name'].should == "p"
  end

  it "should sort by property value on GET /nodes/RestPerson?sort=name,desc" do
    # given
    p1 = RestPerson.new
    p1.name = 'p1'
    p2 = RestPerson.new
    p2.name = 'p2'
    Neo4j::Transaction.current.success # ensure index gets updated
    Neo4j::Transaction.finish

    # when
    get "/nodes/RestPerson?sort=name,desc"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.size.should == 2
    data[0]['name'].should == "p2"
    data[1]['name'].should == "p1"
  end

  it "should treat GET /nodes/SomethingElse?search=... as a Lucene query string" do
    # given
    p1 = SomethingElse.new
    p1.name = 'the supplier'
    p2 = SomethingElse.new
    p2.name = 'the customer'
    Neo4j::Transaction.current.success # ensure index gets updated
    Neo4j::Transaction.finish

    # when
    get "/nodes/SomethingElse?search=name:cutsomer~" # typo to test fuzzy matching

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.size.should == 1
    data[0]['name'].should == "the customer"
  end

  it "should return a subset of nodes on GET /nodes/RestPerson?limit=50,10" do
    # given
    100.times{|n| RestPerson.new.name = 'p' + sprintf('%02d', n) }
    Neo4j::Transaction.current.success # ensure index gets updated
    Neo4j::Transaction.finish

    # when
    get "/nodes/RestPerson?sort=name,desc&limit=50,10"

    # then
    last_response.status.should == 200
    data = JSON.parse(last_response.body)
    data.size.should == 10
    data.map{|p| p['name']}.should == %w(p49 p48 p47 p46 p45 p44 p43 p42 p41 p40)
  end
end