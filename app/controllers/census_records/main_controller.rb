# frozen_string_literal: true

# Base class for census record CRUD actions.
module CensusRecords
  class MainController < ApplicationController
    include FastMemoize
    include AdvancedRestoreSearch
    include RenderCsv

    prepend_before_action :check_access, except: :rebuild
    prepend_before_action :check_demographics_access, only: :demographics

    respond_to :json, only: :index
    respond_to :csv, only: :index
    respond_to :html

    def rebuild
      authorize! :manage, :all
      CensusYears.each do |year|
        "Census#{year}Record".constantize.rebuild_pg_search_documents
      end
      flash[:notice] = "Person index rebuilt."
      redirect_back_or_to(root_path)
    end

    def index
      @page_title = page_title
      load_census_records
      render_census_records
    end

    def advanced_search_filters; end

    def show
      @model = resource_class.find params[:id]
      authorize! :read, @model
      @record = @model.decorate
      load_navigation
    end

    def new
      authorize! :create, resource_class
      @record = resource_class.new
      @record.set_defaults
      @record.attributes = params.require(:attributes).permit! if params[:attributes]
      @record.locality = Locality.first if Locality.count == 1
    end

    # Used to populate the building_id field on census forms
    def building_autocomplete
      record = resource_class.new street_house_number: params[:house],
                                  street_prefix: params[:prefix],
                                  street_name: params[:street],
                                  street_suffix: params[:suffix],
                                  locality_id: params[:locality_id]
      record.auto_strip_attributes
      buildings = Buildings::PossibleMatches.perform(record)
      render json: buildings.to_json
    end

    # Any text field that has autocomplete=off is hooked up to autocomplete based on controlled vocabulary and other
    # entries for that field for that year.
    def autocomplete
      results = AttributeAutocomplete.new(
        attribute: params[:attribute],
        term: params[:term],
        year:,
      ).perform
      render json: results
    end

    def demographics
      load_census_records
      @page_title = "Demographics for #{year} US Census"
    end

    def edit
      @record = resource_class.find params[:id]
      authorize! :update, @record
    end

    def create
     
      @record = resource_class.new resource_params
      authorize! :create, @record
      
      @record.created_by = current_user
      
     if  resource_class.all.empty?
      @record.id  = 1
     else
      @record.id = resource_class.all.maximum(:id).next
     end
      if @record.save
        flash[:notice] = "Census Record saved."
        after_saved
      else
        flash[:error] = "Census Record not saved."
        render action: :new
      end
    end

    def update
      @record = resource_class.find params[:id]
      authorize! :update, @record
      if @record.update(resource_params)
        flash[:notice] = "Census Record saved."
        after_saved
      else
        flash[:error] = "Census Record not saved."
        render action: :edit
      end
    end

    def destroy
      @record = resource_class.find params[:id]
      authorize! :destroy, @record
      if @record.destroy
        flash[:notice] = "Census Record deleted."
        redirect_to action: :index
      else
        flash[:error] = "Unable to delete census record."
        redirect_back fallback_location: { action: :index }
      end
    end

    def save_as
      @record = resource_class.find params[:id]
      authorize! :create, resource_class
      after_saved
    end

    def reviewed
      @record = resource_class.find params[:id]
      authorize! :review, @record
      @record.review! current_user
      flash[:notice] = "The census record is marked as reviewed and available for public view."
      redirect_back fallback_location: { action: :index }
    end

    def bulk_review
      authorize! :review, resource_class
      params[:from] = 0
      params[:to] = 100
      load_census_records

      @search.scoped.to_a.each do |record|
        next if record.reviewed?

        record.review! current_user
      end

      flash[:notice] = "The census records are marked as reviewed and available for public view."
      redirect_back fallback_location: { action: :index }
    end

    def bulk_person_match
      authorize! :review, resource_class
      params[:from] = 0
      params[:to] = 100
      load_census_records

      count = 0
      @search.scoped.to_a.each do |record|
        next if record.person_id.present?

        People::GenerateFromCensusRecord.run!(record:)
        count += 1
      end

      flash[:notice] = "Person records have been generated for #{count} census records."
      redirect_back fallback_location: { action: :index }
    end

    def make_person
      @record = resource_class.find params[:id]
      authorize! :create, resource_class
      person = People::GenerateFromCensusRecord.run!(record: @record)
      if person.persisted?
        flash[:notice] = "A new person record has been created from this census record."
      else
        error_message = "Unable to create a person record from this census record. "
        error_message += person.errors.full_messages.to_sentence if person.errors.any?
        flash[:error] = error_message
      end
      redirect_back fallback_location: { action: :index }
    end

    def year
      params[:year].to_i
    end

    memoize :year
    helper_method :year

    private

    def load_navigation
      # Load navigation data if there are active search parameters
      return unless has_active_search_data?

      @navigation = CensusRecordSearch.generate(params: current_search_data, year:, user: current_user).navigation_neighbors(@model.id)
    end

    def search_key
      CensusYears.to_words(year)
    end

    memoize :search_key

    # This is a blanket access check for whether this census year is activated for this HF instance
    def check_access
      permission_denied unless can_census?(year)
    end

    def check_demographics_access
      permission_denied unless can_demographics?(year)
    end

    def resource_class
      "Census#{year}Record".safe_constantize
    end

    memoize :resource_class
    helper_method :resource_class

    NULLABLES = %w[on nil].freeze

    def resource_params
      params[:census_record].each do |key2, value|
        params[:census_record][key2] = nil if NULLABLES.include?(value)
      end
      params.require(:census_record).permit!
    end

    def after_saved
      if params[:context] && params[:context] == "person"
        redirect_to @record.person
      elsif params[:then].present?
        attributes = NextCensusRecordAttributes.new(@record, params[:then]).attributes
        redirect_to send(:"new_census#{year}_record_path", attributes:)
      else
        redirect_to @record
      end
    end

    def search_params
      params.permit!.to_h
    end

    def load_census_records
      authorize! :read, resource_class
      @search = CensusRecordSearch.generate params: search_params, year:, user: current_user
    end

    def render_census_records
      @translator = CensusGridTranslator.new(@search)
      respond_to do |format|
        format.html { render action: :index }
        format.csv { render_csv("census-records-#{year}", resource_class) }
        format.json { render_json }
      end
    end

    def render_json
      if params[:from]
        render json: @translator.row_data
      else
        respond_with @search.to_a, each_serializer: CensusRecordSerializer
      end
    end

    def census_record_search_class
      "CensusRecord#{year}Search".safe_constantize
    end

    memoize :census_record_search_class

    def page_title
      "#{year} US Census Records"
    end
  end
end
